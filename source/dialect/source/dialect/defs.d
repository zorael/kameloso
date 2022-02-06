
module dialect.defs;

import lu.uda;

struct IRCEvent
{
    
    enum Type
    {
        UNSET,      
        ANY,        
        ERROR,      
        NUMERIC,    
        PRIVMSG,    
        CHAN,       
        QUERY,      
        EMOTE,      
        SELFQUERY,  
        SELFCHAN,   
        SELFEMOTE,  
        AWAY,       
        BACK,       
        JOIN,       
        PART,       
        QUIT,       
        KICK,       
        INVITE,     
        NOTICE,     
        PING,       
        PONG,       
        NICK,       
        MODE,       
        SELFQUIT,   
        SELFJOIN,   
        SELFPART,   
        SELFMODE,   
        SELFNICK,   
        SELFKICK,   
        TOPIC,      
        CAP,        
        CTCP_VERSION,
        CTCP_TIME,  
        CTCP_PING,  
        CTCP_CLIENTINFO,
        CTCP_DCC,   
        CTCP_SOURCE,
        CTCP_USERINFO,
        CTCP_FINGER,
        CTCP_LAG,   
        CTCP_AVATAR,
        CTCP_SLOTS, 
        ACCOUNT,    
        WALLOPS,    
        SASL_AUTHENTICATE,
        AUTH_CHALLENGE,   
        AUTH_FAILURE,     
        AUTH_SUCCESS,     
        CHGHOST,          
        CHANNELFORBIDDEN, 
        BOTSNOTWELCOME,   
        ENDOFSPAMFILTERLIST,
        SPAMFILTERLIST,   
        NICKUNLOCKED,     
        NICKNOTLOCKED,    
        ENDOFEXEMPTOPSLIST,
        MODELIST,         
        ENDOFMODELIST,    
        ENDOFCHANNELACCLIST, 

        
        USERSTATE,        
        ROOMSTATE,        
        GLOBALUSERSTATE,  
        CLEARCHAT,        
        CLEARMSG,         
        USERNOTICE,       
        HOSTTARGET,       
        RECONNECT,        
        WHISPER,          
        TWITCH_NOTICE,    
        TWITCH_ERROR,     
        TWITCH_TIMEOUT,   
        TWITCH_BAN,       
        TWITCH_SUB,       
        TWITCH_CHEER,     
        TWITCH_SUBGIFT,   
        TWITCH_HOSTSTART, 
        TWITCH_HOSTEND,   
        TWITCH_BITSBADGETIER, 
        TWITCH_RAID,      
        TWITCH_UNRAID,    
        TWITCH_RITUAL,    
        TWITCH_REWARDGIFT,
        TWITCH_GIFTCHAIN, 
        TWITCH_SUBUPGRADE,
        TWITCH_CHARITY,   
        TWITCH_BULKGIFT,  
        TWITCH_EXTENDSUB, 
        TWITCH_GIFTRECEIVED , 
        TWITCH_PAYFORWARD,
        TWITCH_CROWDCHANT,

        RPL_WELCOME, 
        RPL_YOURHOST, 
        RPL_CREATED, 
        RPL_MYINFO, 
        RPL_BOUNCE, 
        RPL_ISUPPORT, 
        RPL_MAP, 
        RPL_MAPEND, 
        RPL_SNOMASK, 
        RPL_STATMEMTOT, 
        
        RPL_STATMEM, 
        RPL_YOURCOOKIE, 
        
        RPL_MAPMORE, 
        
        RPL_HELLO, 
        RPL_APASSWARN_SET, 
        RPL_APASSWARN_SECRET, 
        RPL_APASSWARN_CLEAR, 
        RPL_YOURID, 
        RPL_SAVENICK, 
        RPL_ATTEMPTINGJUNC, 
        RPL_ATTEMPTINGREROUTE, 

        RPL_REMOTEISUPPORT, 

        RPL_TRACELINK, 
        RPL_TRACECONNECTING, 
        RPL_TRACEHANDSHAKE, 
        RPL_TRACEUNKNOWN, 
        RPL_TRACEOPERATOR, 
        RPL_TRACEUSER, 
        RPL_TRACESERVER, 
        RPL_TRACESERVICE, 
        RPL_TRACENEWTYPE, 
        RPL_TRACECLASS, 
        RPL_TRACERECONNECT, 
        RPL_STATSHELP, 
        RPL_STATS, 
        RPL_STATSLINKINFO, 
        RPL_STATSCOMMAND, 
        RPL_STATSCLINE, 
        RPL_STATSNLINE, 
        RPL_STATSILINE, 
        RPL_STATSKLINE, 
        RPL_STATSPLINE, 
        RPL_STATSQLINE, 
        RPL_STATSYLINE, 
        RPL_ENDOFSTATS, 
        RPL_STATSBLINE, 
        RPL_STATSWLINE, 
        
        RPL_UMODEIS, 
        
        RPL_SQLINE_NICK, 
        RPL_CODEPAGE, 
        RPL_STATSJLINE, 
        RPL_MODLIST, 
        RPL_STATSGLINE, 
        RPL_CHARSET, 
        RPL_STATSELINE, 
        RPL_STATSTLINE, 
        RPL_STATSFLINE, 
        
        RPL_STATSZLINE, 
        RPL_STATSCLONE, 
        RPL_STATSDLINE, 
        
        RPL_STATSALINE, 
        RPL_STATSCOUNT, 
        
        RPL_STATSVLINE, 
        
        RPL_STATSBANVER, 
        
        RPL_STATSSPAMF, 
        RPL_STATSEXCEPTTKL, 
        RPL_SERVICEINFO, 
        RPL_RULES, 
        RPL_ENDOFSERVICES, 
        RPL_SERVICE, 
        RPL_SERVLIST, 
        RPL_SERVLISTEND, 
        RPL_STATSVERBOSE, 
        RPL_STATSENGINE, 
        
        RPL_STATSIAUTH, 
        RPL_STATSXLINE, 
        
        RPL_STATSLLINE, 
        RPL_STATSUPTIME, 
        RPL_STATSOLINE, 
        RPL_STATSHLINE, 
        
        RPL_STATSSLINE, 
        RPL_STATSSERVICE, 
        
        RPL_STATSULINE, 
        RPL_STATSPING, 
        
        
        
        RPL_STATSDEFINE, 
        
        RPL_STATSDEBUG, 
        
        
        RPL_STATSCONN, 
        RPL_LUSERCLIENT, 
        RPL_LUSEROP, 
        RPL_LUSERUNKNOWN, 
        RPL_LUSERCHANNELS, 
        RPL_LUSERME, 
        RPL_ADMINME, 
        RPL_ADMINLOC1, 
        RPL_ADMINLOC2, 
        RPL_ADMINEMAIL, 
        RPL_TRACELOG, 
        RPL_TRACEPING, 
        RPL_TRACEEND, 
        RPL_TRYAGAIN, 
        RPL_USINGSSL, 
        RPL_LOCALUSERS, 
        RPL_GLOBALUSERS, 
        RPL_START_NETSTAT, 
        RPL_NETSTAT, 
        RPL_END_NETSTAT, 
        RPL_MAPUSERS, 
        RPL_PRIVS, 
        RPL_SILELIST, 
        RPL_ENDOFSILELIST, 
        RPL_NOTIFY, 
        RPL_STATSDELTA, 
        RPL_ENDNOTIFY, 
        
        
        RPL_VCHANEXIST, 
        RPL_WHOISCERTFP, 
        RPL_STATSRLINE, 
        RPL_VCHANLIST, 
        RPL_VCHANHELP, 
        RPL_GLIST, 
        RPL_ENDOFGLIST, 
        RPL_ACCEPTLIST, 
        RPL_JUPELIST, 
        RPL_ENDOFACCEPT, 
        RPL_ENDOFJUPELIST, 
        RPL_ALIST, 
        RPL_FEATURE, 
        RPL_ENDOFALIST, 
        RPL_CHANINFO_HANDLE, 
        RPL_NEWHOSTIS, 
        RPL_GLIST_HASH, 
        RPL_CHKHEAD, 
        RPL_CHANINFO_USERS, 
        RPL_CHANUSER, 
        RPL_CHANINFO_CHOPS, 
        RPL_PATCHHEAD, 
        RPL_CHANINFO_VOICES, 
        RPL_PATCHCON, 
        RPL_CHANINFO_AWAY, 
        RPL_CHANINFO_HELPHDR, 
        RPL_DATASTR, 
        RPL_HELPHDR, 
        RPL_CHANINFO_OPERS, 
        RPL_ENDOFCHECK, 
        RPL_HELPOP, 
        RPL_CHANINFO_BANNED, 
        ERR_SEARCHNOMATCH, 
        RPL_HELPTLR, 
        RPL_CHANINFO_BANS, 
        RPL_HELPHLP, 
        RPL_CHANINFO_INVITE, 
        RPL_HELPFWD, 
        RPL_CHANINFO_INVITES, 
        RPL_HELPIGN, 
        RPL_CHANINFO_KICK, 
        RPL_CHANINFO_KICKS, 
        RPL_END_CHANINFO, 

        RPL_NONE, 
        RPL_AWAY, 
        RPL_USERHOST, 
        RPL_ISON, 
        RPL_SYNTAX, 
        RPL_TEXT, 
        RPL_UNAWAY, 
        RPL_NOWAWAY, 
        RPL_SUSERHOST, 
        RPL_USERIP, 
        RPL_WHOISREGNICK, 
        RPL_WHOISADMIN, 
        RPL_RULESSTART, 
        RPL_NOTIFYACTION, 
        RPL_WHOISHELPER, 
        RPL_ENDOFRULES, 
        
        RPL_NICKTRACE, 
        RPL_WHOISSERVICE, 
        RPL_WHOISHELPOP, 
        RPL_WHOISSVCMSG, 
        RPL_WHOISUSER, 
        RPL_WHOISSERVER, 
        RPL_WHOISOPERATOR, 
        RPL_WHOWASUSER, 
        RPL_ENDOFWHO, 
        RPL_WHOISPRIVDEAF, 
        RPL_WHOISCHANOP, 
        RPL_WHOISIDLE, 
        RPL_ENDOFWHOIS, 
        RPL_WHOISCHANNELS, 
        RPL_WHOISVIRT, 
        RPL_WHOIS_HIDDEN, 
        RPL_WHOISSPECIAL, 
        RPL_LISTSTART, 
        RPL_LIST, 
        RPL_LISTEND, 
        RPL_CHANNELMODEIS, 
        RPL_WHOISWEBIRC, 
        RPL_CHANNELMLOCKIS, 
        RPL_UNIQOPIS, 
        RPL_CHANNELPASSIS, 
        RPL_NOCHANPASS, 
        
        RPL_CHPASSUNKNOWN, 
        RPL_CHANNEL_URL, 
        RPL_CREATIONTIME, 
        RPL_WHOWAS_TIME, 
        RPL_WHOISACCOUNT, 
        RPL_NOTOPIC, 
        RPL_TOPIC, 
        RPL_TOPICWHOTIME, 
        RPL_COMMANDSYNTAX, 
        RPL_LISTSYNTAX, 
        RPL_LISTUSAGE, 
        RPL_WHOISTEXT, 
        RPL_WHOISACCOUNTONLY, 
        RPL_WHOISBOT, 
        
        RPL_INVITELIST, 
        
        RPL_ENDOFINVITELIST, 
        RPL_CHANPASSOK, 
        RPL_WHOISACTUALLY, 
        RPL_WHOISMARKS, 
        RPL_BADCHANPASS, 
        
        RPL_INVITING, 
        RPL_SUMMONING, 
        RPL_WHOISKILL, 
        RPL_REOPLIST, 
        RPL_ENDOFREOPLIST, 
        RPL_INVITED, 
        
        
        RPL_EXCEPTLIST, 
        RPL_ENDOFEXCEPTLIST, 
        RPL_VERSION, 
        RPL_WHOREPLY, 
        RPL_NAMREPLY, 
        RPL_WHOSPCRPL, 
        RPL_NAMREPLY_, 
        
        
        
        RPL_WHOWASREAL, 
        RPL_KILLDONE, 
        RPL_CLOSING, 
        RPL_CLOSEEND, 
        RPL_LINKS, 
        RPL_ENDOFLINKS, 
        RPL_ENDOFNAMES, 
        RPL_BANLIST, 
        RPL_ENDOFBANLIST, 
        RPL_ENDOFWHOWAS, 
        RPL_INFO, 
        RPL_MOTD, 
        RPL_INFOSTART, 
        RPL_ENDOFINFO, 
        RPL_MOTDSTART, 
        RPL_ENDOFMOTD, 
        RPL_SPAM, 
        RPL_KICKEXPIRED, 
        RPL_BANEXPIRED, 
        
        RPL_WHOISHOST, 
        RPL_KICKLINKED, 
        RPL_WHOWASIP, 
        RPL_WHOISMODES, 
        RPL_YOURHELPER, 
        RPL_BANLINKED, 
        RPL_YOUREOPER, 
        RPL_REHASHING, 
        RPL_YOURESERVICE, 
        RPL_MYPORTIS, 
        RPL_NOTOPERANYMORE, 
        RPL_IRCOPS, 
        RPL_IRCOPSHEADER, 
        RPL_RSACHALLENGE, 
        RPL_QLIST, 
        RPL_ENDOFIRCOPS, 
        
        RPL_ENDOFQLIST, 
        
        
        
        RPL_TIME, 
        RPL_USERSTART, 
        RPL_USERS, 
        RPL_ENDOFUSERS, 
        RPL_NOUSERS, 
        RPL_VISIBLEHOST, 
        RPL_HOSTHIDDEN, 

        ERR_UNKNOWNERROR, 
        ERR_NOSUCHNICK, 
        ERR_NOSUCHSERVER, 
        ERR_NOSUCHCHANNEL, 
        ERR_CANNOTSENDTOCHAN, 
        ERR_TOOMANYCHANNELS, 
        ERR_WASNOSUCHNICK, 
        ERR_TOOMANYTARGETS, 
        ERR_NOCTRLSONCHAN, 
        ERR_NOCOLORSONCHAN, 
        ERR_NOSUCHSERVICE, 
        ERR_NOORIGIN, 
        ERR_INVALIDCAPCMD, 
        ERR_NORECIPIENT, 
        ERR_NOTEXTTOSEND, 
        ERR_NOTOPLEVEL, 
        ERR_WILDTOPLEVEL, 
        ERR_BADMASK, 
        ERR_QUERYTOOLONG, 
        ERR_TOOMANYMATCHES, 
        ERR_INPUTTOOLONG, 
        ERR_LENGTHTRUNCATED, 
        ERR_UNKNOWNCOMMAND, 
        ERR_NOMOTD, 
        ERR_NOADMININFO, 
        ERR_FILEERROR, 
        ERR_NOOPERMOTD, 
        ERR_TOOMANYAWAY, 
        ERR_EVENTNICKCHANGE, 
        ERR_NONICKNAMEGIVEN, 
        ERR_ERRONEOUSNICKNAME, 
        ERR_NICKNAMEINUSE, 
        ERR_SERVICENAMEINUSE, 
        ERR_NORULES, 
        ERR_SERVICECONFUSED, 
        ERR_BANONCHAN, 
        ERR_NICKCOLLISION, 
        ERR_BANNICKCHANGE, 
        ERR_UNAVAILRESOURCE, 
        ERR_DEAD, 
        ERR_NICKTOOFAST, 
        ERR_TARGETTOOFAST, 
        ERR_SERVICESDOWN, 
        ERR_USERNOTINCHANNEL, 
        ERR_NOTONCHANNEL, 
        ERR_USERONCHANNEL, 
        ERR_NOLOGIN, 
        ERR_SUMMONDISABLED, 
        ERR_USERSDISABLED, 
        ERR_NONICKCHANGE, 
        ERR_FORBIDDENCHANNEL, 
        ERR_NOTIMPLEMENTED, 
        ERR_NOTREGISTERED, 
        ERR_IDCOLLISION, 
        ERR_NICKLOST, 
        
        ERR_HOSTILENAME, 
        ERR_ACCEPTFULL, 
        ERR_ACCEPTEXIST, 
        ERR_ACCEPTNOT, 
        ERR_NOHIDING, 
        ERR_NOTFORHALFOPS, 
        ERR_NEEDMOREPARAMS, 
        ERR_ALREADYREGISTERED, 
        ERR_NOPERMFORHOST, 
        ERR_PASSWDMISMATCH, 
        ERR_YOUREBANNEDCREEP, 
        ERR_YOUWILLBEBANNED, 
        ERR_KEYSET, 
        ERR_NOCODEPAGE, 
        ERR_ONLYSERVERSCANCHANGE, 
        ERR_INVALIDUSERNAME, 
        ERR_LINKSET, 
        ERR_7BIT, 
        ERR_KICKEDFROMCHAN, 
        ERR_LINKCHANNEL, 
        ERR_CHANNELISFULL, 
        ERR_UNKNOWNMODE, 
        ERR_INVITEONLYCHAN, 
        ERR_BANNEDFROMCHAN, 
        ERR_BADCHANNELKEY, 
        ERR_BADCHANMASK, 
        ERR_NOCHANMODES, 
        ERR_NEEDREGGEDNICK, 
        ERR_BANLISTFULL, 
        ERR_NOCOLOR, 
        ERR_BADCHANNAME, 
        ERR_LINKFAIL, 
        ERR_THROTTLE, 
        ERR_NOWALLOP, 
        ERR_SSLONLYCHAN, 
        ERR_NOULINE, 
        ERR_CANNOTKNOCK, 
        ERR_NOPRIVILEGES, 
        ERR_CHANOPRIVSNEEDED, 
        ERR_CANTKILLSERVER, 
        ERR_ATTACKDENY, 
        ERR_DESYNC, 
        ERR_ISCHANSERVICE, 
        ERR_RESTRICTED, 
        ERR_BANNEDNICK, 
        ERR_CHANBANREASON, 
        ERR_KILLDENY, 
        ERR_CANTKICKADMIN, 
        ERR_ISREALSERVICE, 
        ERR_UNIQPRIVSNEEDED, 
        ERR_ACCOUNTONLY, 
        ERR_RLINED, 
        ERR_HTMDIABLED, 
        ERR_NONONREG, 
        ERR_NONONSSL, 
        ERR_NOTFORUSERS, 
        ERR_CHANTOORECENT, 
        ERR_MSGSERVICES, 
        ERR_HTMDISABLED, 
        ERR_NOSSL, 
        ERR_TSLESSCHAN, 
        ERR_VOICENEEDED, 
        ERR_SECUREONLYCHAN, 
        ERR_NOSWEAR, 
        ERR_ALLMUSTSSL, 
        ERR_NOOPERHOST, 
        ERR_CANNOTSENDTOUSER, 
        ERR_NOCTCP, 
        ERR_NOTCP, 
        ERR_NOSERVICEHOST, 
        ERR_NOSHAREDCHAN, 
        ERR_NOFEATURE, 
        ERR_OWNMODE, 
        ERR_BADFEATVALUE, 
        ERR_DELAYREJOIN, 
        ERR_BADLOGTYPE, 
        ERR_BADLOGSYS, 
        ERR_BADLOGVALUE, 
        ERR_ISOPERLCHAN, 
        ERR_CHANOWNPRIVNEEDED, 

        ERR_NOREHASHPARAM, 
        ERR_TOOMANYJOINS, 
        ERR_UNKNOWNSNOMASK, 
        ERR_UMODEUNKNOWNFLAG, 
        ERR_USERSDONTMATCH, 
        ERR_VWORLDWARN, 
        ERR_GHOSTEDCLIENT, 
        ERR_USERNOTONSERV, 
        ERR_SILELISTFULL, 
        ERR_NOSUCHGLINE, 
        ERR_TOOMANYWATCH, 
        
        ERR_NEEDPONG, 
        ERR_NOSUCHJUPE, 
        ERR_TOOMANYDCC, 
        ERR_INVALID_ERROR, 
        ERR_BADEXPIRE, 
        ERR_DONTCHEAT, 
        ERR_DISABLED, 
        ERR_NOINVITE, 
        ERR_LONGMASK, 
        ERR_ADMONLY, 
        ERR_TOOMANYUSERS, 
        ERR_WHOTRUNC, 
        ERR_MASKTOOWIDE, 
        ERR_OPERONLY, 
        
        ERR_LISTSYNTAX, 
        ERR_WHOSYNTAX, 
        ERR_WHOLIMEXCEED, 
        ERR_OPERSPVERIFY, 
        ERR_QUARANTINED, 
        ERR_HELPNOTFOUND, 
        ERR_INVALIDKEY, 
        ERR_REMOTEPFX, 
        ERR_PFXUNROUTABLE, 
        ERR_CANTSENDTOUSER, 
        ERR_BADHOSTMASK, 
        ERR_HOSTUNAVAIL, 
        ERR_USINGSLINE, 
        ERR_STATSSLINE, 
        ERR_NOTLOWEROPLEVEL, 
        ERR_NOTMANAGER, 
        ERR_CHANSECURED, 
        ERR_UPASSSET, 
        ERR_UPASSNOTSET, 
        ERR_NOMANAGER, 
        ERR_UPASS_SAME_APASS, 
        RPL_NOMOTD, 
        ERR_LASTERROR, 
        RPL_REAWAY, 
        RPL_GONEAWAY, 
        RPL_NOTAWAY, 

        RPL_LOGON, 
        RPL_LOGOFF, 
        RPL_WATCHOFF, 
        RPL_WATCHSTAT, 
        RPL_NOWON, 
        RPL_NOWFF, 
        RPL_WATCHLIST, 
        RPL_ENDOFWATCHLIST, 
        RPL_WATCHCLEAR, 
        RPL_NOWISAWAY, 
        RPL_ISOPER, 
        
        RPL_ISLOCOP, 
        RPL_ISNOTOPER, 
        RPL_ENDOFISOPER, 
        
        
        
        RPL_WHOISSSLFP, 
        
        RPL_DCCSTATUS, 
        RPL_DCCLIST, 
        RPL_WHOWASHOST, 
        RPL_ENDOFDCCLIST, 
        
        RPL_DCCINFO, 
        
        
        
        RPL_OMOTDSTART, 
        RPL_OMOTD, 
        RPL_ENDOFO, 
        RPL_SETTINGS, 
        RPL_ENDOFSETTINGS, 
        RPL_DUMPING, 
        RPL_DUMPRPL, 
        RPL_EODUMP, 
        RPL_SPAMCMDFWD, 
        RPL_TRACEROUTE_HOP, 
        RPL_TRACEROUTE_START, 
        RPL_MODECHANGEWARN, 
        RPL_CHANREDIR, 
        RPL_SERVMODEIS, 
        RPL_OTHERUMODEIS, 
        RPL_ENDOF_GENERIC, 
        RPL_WHOWASDETAILS, 
        RPL_STARTTLS, 
        RPL_WHOISSECURE, 
        RPL_UNKNOWNMODES, 
        RPL_WHOISREALIP, 
        RPL_CANNOTSETMODES, 
        RPL_WHOISYOURID, 
        RPL_LUSERSTAFF, 
        RPL_TIMEONSERVERIS, 
        RPL_NETWORKS, 
        RPL_YOURLANGUAGEIS, 
        RPL_LANGUAGE, 
        RPL_WHOISSTAFF, 
        RPL_WHOISLANGUAGE, 
        ERR_STARTTLS, 

        
        RPL_COMMANDS, 
        RPL_ENDOFMODLIST, 
        RPL_COMMANDSEND, 
        RPL_HELPSTART, 
        RPL_HELPTXT, 
        RPL_ENDOFHELP, 
        ERR_TARGCHANGE, 
        RPL_ETRACEFULL, 
        RPL_ETRACE, 
        RPL_KNOCK, 
        RPL_KNOCKDLVR, 
        ERR_TOOMANYKNOCK, 
        ERR_CHANOPEN, 
        ERR_KNOCKONCHAN, 
        ERR_KNOCKDISABLED, 
        ERR_TOOMANYINVITE, 
        RPL_INVITETHROTTLE, 
        RPL_TARGUMODEG, 
        RPL_TARGNOTIFY, 
        RPL_UMODEGMSG, 
        
        
        RPL_ENDOFOMOTD, 
        ERR_NOPRIVS, 
        RPL_TESTMASK, 
        RPL_TESTLINE, 
        RPL_NOTESTLINE, 
        RPL_TESTMASKGECOS, 
        RPL_QUIETLIST, 
        RPL_ENDOFQUIETLIST, 
        RPL_MONONLINE, 
        RPL_MONOFFLINE, 
        RPL_MONLIST, 
        RPL_ENDOFMONLIST, 
        ERR_MONLISTFULL, 
        RPL_RSACHALLENGE2, 
        RPL_ENDOFRSACHALLENGE2, 
        ERR_MLOCKRESTRICTED, 
        ERR_INVALIDBAN, 
        ERR_TOPICLOCK, 
        RPL_SCANMATCHED, 
        RPL_SCANUMODES, 
        RPL_ETRACEEND, 
        RPL_WHOISKEYVALUE, 
        RPL_KEYVALUE, 
        RPL_METADATAEND, 
        ERR_METADATALIMIT, 
        ERR_TARGETINVALID, 
        ERR_NOMATCHINGKEY, 
        ERR_KEYINVALID, 
        ERR_KEYNOTSET, 
        ERR_KEYNOPERMISSION, 
        RPL_XINFO, 
        RPL_XINFOSTART, 
        RPL_XINFOEND, 

        RPL_CHECK, 

        RPL_LOGGEDIN, 
        RPL_LOGGEDOUT, 
        ERR_NICKLOCKED, 
        RPL_SASLSUCCESS, 
        ERR_SASLFAIL, 
        ERR_SASLTOOLONG, 
        ERR_SASLABORTED, 
        ERR_SASLALREADY, 
        RPL_SASLMECHS, 
        ERR_WORDFILTERED, 
        ERR_CANTUNLOADMODULE, 
        ERR_CANNOTDOCOMMAND, 
        ERR_CANNOTCHANGEUMODE, 
        ERR_CANTLOADMODULE, 
        ERR_CANNOTCHANGECHANMODE, 
        ERR_CANNOTCHANGESERVERMODE, 
        
        RPL_LOADEDMODULE, 
        ERR_CANNOTSENDTONICK, 
        ERR_UNKNOWNSERVERMODE, 
        ERR_SERVERMODELOCK, 
        ERR_BADCHARENCODING, 
        ERR_TOOMANYLANGUAGES, 
        ERR_NOLANGUAGE, 
        ERR_TEXTTOOSHORT, 

        ERR_NUMERIC_ERR, 
    }

    

    
    Type type;

string raw;

    
    IRCUser sender;

    
    string channel;

    
    IRCUser target;

    
    string content;

    
    string aux;

    
    string tags;

}




struct IRCServer
{
    
    enum Daemon
    {
        unset,      
        unknown,    

        unreal,
        solanum,
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
        bsdunix,
        mfvx,

        charybdis,
        sorircd,

        ircu,
        aircd,
        rfc1459,
        rfc2812,
        nefarious,
        rusnet,
        ircnet,
        ptlink,
        ultimate,
        anothernet,
        bdqircd,
        chatircd,
        irch,
        ithildin,
    }

    
    enum CaseMapping
    {
        
        ascii,
        
        rfc1459,
        
        strict_rfc1459,
    }

    
    string address;

    
    ushort port;

        
        Daemon daemon;

        
        uint maxNickLength ;

        
        char[] prefixchars;

        
        CaseMapping caseMapping;

        
        char extbanPrefix ;

}




struct IRCUser
{
    
    enum Class
    {
        unset,      
    }

    
    string nickname;

    
    string address;

    
    string account;

    
    Class class_;

    
    bool isServer() const     {
        return !nickname;
    }

    
    unittest
    {
"kameloso";
    }

}




struct Typenums
{
    
}




struct IRCChannel
{
    
    struct Mode
    {
        
        char modechar;

        
        string data;

        
        IRCUser user;

        
        string channel;

        
        IRCUser[] exceptions;

    }

    
    Mode[] modes;

    
    bool[] users;

}




struct IRCClient
{
    
    string nickname; 

    
    string realName; 

        
        string origNickname;

}

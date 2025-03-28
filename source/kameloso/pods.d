/++
    POD structs, broken out of [kameloso.kameloso] to avoid cyclic dependencies.

    See_Also:
        [kameloso.kameloso]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.pods;


// CoreSettings
/++
    Aggregate struct containing runtime bot setting variables.

    Kept inside one struct, they're nicely gathered and easy to pass around.
    Some defaults are hardcoded here.
 +/
struct CoreSettings
{
private:
    import lu.uda : CannotContainComments, Hidden, Quoted, Unserialisable;

public:
    version(Colours)
    {
        // version Colours colours
        /++
            Terminal output colour setting.
         +/
        bool colours = true;
    }
    else
    {
        // non-version Colours colours
        /++
            Non-version Colours version defaults to false.
         +/
        bool colours = false;
    }

    // brightTerminal
    /++
        Whether or not he terminal has a bright background.
     +/
    bool brightTerminal = false;

    // extendedColours
    /++
        Whether or not the bot should output text using extended ANSI sequences.
     +/
    bool extendedColours = true;

    // preferHostmasks
    /++
        Whether or not hostmasks should be used instead of accounts to authenticate users.
     +/
    bool preferHostmasks = false;

    // hideOutgoing
    /++
        Whether or not to hide outgoing messages, not printing them to screen.
     +/
    bool hideOutgoing = false;

    // colouredOutgoing
    /++
        Whether or not to add colours to outgoing messages.
     +/
    bool colouredOutgoing = true;

    // extendedOutgoingColours
    /++
        Whether or not to add extended colours to outgoing messages.

        If false, only basic colours will be used.
     +/
    bool extendedOutgoingColours = true;

    // reexecToReconnect
    /++
        Re-executes the program instead of reconnecting hot.
     +/
    bool reexecToReconnect = false;

    // saveOnExit
    /++
        Whether or not we should save configuration changes to file on exit.
     +/
    bool saveOnExit = false;

    // exitSummary
    /++
        Whether or not to display a connection summary on program exit.
     +/
    bool exitSummary = false;

    @Hidden
    {
        // eagerLookups
        /++
            Whether to eagerly and exhaustively WHOIS all participants in home channels,
            or to do a just-in-time lookup when needed.
         +/
        bool eagerLookups = false;

        // headless
        /++
            Whether or not to be "headless", disabling all terminal output.
         +/
        bool headless;
    }

    // resourceDirectory
    /++
        Path to resource directory.
     +/
    @Hidden
    @CannotContainComments
    string resourceDirectory;

    // prefix
    /++
        Character(s) that prefix a bot chat command.

        These decide what bot commands will look like; "!" for "!command",
        "~" for "~command", "." for ".command", etc. It can be any string and
        not just one character.
     +/
    @Quoted string prefix;  // = "!";

    @Unserialisable
    {
        // configFile
        /++
            Main configuration file.
         +/
        string configFile;

        // configDirectory
        /++
            Path to configuration directory.
         +/
        string configDirectory;

        // force
        /++
            Whether or not to force connecting, skipping some sanity checks.
         +/
        bool force;

        // flush
        /++
            Whether or not to explicitly set stdout to flush after writing a linebreak to it.
         +/
        bool flush;

        // trace
        /++
            Whether or not *all* outgoing messages should be echoed to the terminal.
         +/
        bool trace;

        // numericAddresses
        /++
            Whether to print addresses as IPs or as hostnames (where applicable).
         +/
        bool numericAddresses;

        // observerMode
        /++
            Enables observer mode, which makes the bot ignore all commands
            (but process other events).
         +/
        bool observerMode;

        // callgrind
        /++
            Enables callgrind dumps for profiling.
         +/
        bool callgrind;

        // acceptCommandsFromSubchannels
        /++
            Whether or not to accept commands whose origin channel is the subchannel
            of an event.
         +/
        bool acceptCommandsFromSubchannels = false;
    }
}


// ConnectionSettings
/++
    Aggregate of values used in the connection between the bot and the IRC server.
 +/
struct ConnectionSettings
{
private:
    import kameloso.constants : ConnectionDefaultFloats, Timeout;
    import lu.uda : CannotContainComments, Hidden;

public:
    // ipv6
    /++
        Whether to connect to IPv6 addresses or only use IPv4 ones.
     +/
    bool ipv6 = true;

    @CannotContainComments
    @Hidden
    {
        // privateKeyFile
        /++
            Path to private (`.pem`) key file, used in SSL connections.
         +/
        string privateKeyFile;

        // certFile
        /++
            Path to certificate (`.pem`) file.
         +/
        string certFile;

        // caBundleFile
        /++
            Path to certificate bundle `cacert.pem` file or equivalent.
         +/
        string caBundleFile;
    }

    // ssl
    /++
        Whether or not to attempt an SSL connection.
     +/
    bool ssl = false;

    @Hidden
    {
        // receiveTimeout
        /++
            Socket receive timeout in milliseconds (how often to check for other messages).
         +/
        uint receiveTimeout = Timeout.Integers.receiveMsecs;

        // messageRate
        /++
            How many messages to send per second, maximum.
         +/
        double messageRate = ConnectionDefaultFloats.messageRate;

        // messageBurst
        /++
            How many messages to immediately send in one go, before throttling kicks in.

         +/
        double messageBurst = ConnectionDefaultFloats.messageBurst;
    }
}


// IRCBot
/++
    Aggregate of information relevant for an IRC *bot* that goes beyond what is
    needed for a mere IRC *client*.
 +/
struct IRCBot
{
private:
    import lu.uda : CannotContainComments, Hidden, Separator, Unserialisable;

public:
    // account
    /++
        Username to use as services account login name.
     +/
    string account;

    @Hidden
    @CannotContainComments
    {
        // password
        /++
            Password for services account.
         +/
        string password;

        // pass
        /++
            Login `PASS`, different from `SASL` and services.
         +/
        string pass;

        // quitReason
        /++
            Default reason given when quitting and not specifying a reason text.
         +/
        string quitReason;

        // partReason
        /++
            Default reason given when parting a channel and not specifying a reason text.
         +/
        string partReason;
    }

    @Separator(",")
    @Separator(" ")
    {
        // admins
        /++
            The nickname services accounts of administrators, in a bot-like context.
         +/
        string[] admins;

        // homeChannels
        /++
            List of home channels for the bot to operate in.
         +/
        @CannotContainComments
        string[] homeChannels;

        // guestChannels
        /++
            Currently inhabited non-home guest channels.
         +/
        @CannotContainComments
        string[] guestChannels;
    }

    @Unserialisable
    {
        // hasGuestNickname
        /++
            Whether or not we connected without an explicit nickname, and a random
            guest such was generated.
         +/
        bool hasGuestNickname;

        // channelOverride
        /++
            Snapshot of channels we're in, carried from a previous connection
            (even across re-executions).
         +/
        @Separator(",")
        string[] channelOverride;
    }
}

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


void onPRIVMSG(ref IRCEvent event, ref IRCBot bot, ref string slice)
{
    import kameloso.stringutils : beginsWith;

    // FIXME, change so that it assigns to the proper field

    immutable targetOrChannel = slice.nom(" :");
    event.content = slice;

    if (true)
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
    return IRCEvent.init;
}


/// This simply looks at an event and decides whether it is from a nickname
/// registration service.
bool isFromAuthService(const IRCEvent event, ref IRCBot bot)
{
    return false;
}

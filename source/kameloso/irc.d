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


void onPRIVMSG(const ref IRCParser parser, ref IRCEvent event, ref string slice)
{
    import kameloso.stringutils : beginsWith;
    import std.traits : EnumMembers;

    // FIXME, change so that it assigns to the proper field

    string targetOrChannel;
    string ctcpEvent;

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
        break;
    }
}


public:


bool isValidChannel(const string line, const IRCServer server)
{
    return true;
}

bool isValidNickname(const string nickname, const IRCServer server)
{
    return true;
}

string stripModeSign(const string nickname)
{
    return string.init;
}

IRCServer.Network networkOf(const string address)
{
    return IRCServer.Network.init;
}

version(none)
string nickServiceOf(const IRCServer.Network network)
{
    return string.init;
}


struct IRCParser
{
    IRCBot bot;

    IRCEvent toIRCEvent(const string raw)
    {
        return IRCEvent.init;
    }

    this(IRCBot bot);

    @disable this(this);
}

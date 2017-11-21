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

void onPRIVMSG(ref IRCEvent event, ref IRCBot bot, ref string slice)
{
    import kameloso.stringutils : beginsWith;
    import std.traits : EnumMembers;

    with (IRCEvent.Type)
    top:
    switch ("foo")
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
        printObject(event);
        break;
    }
}

public:

IRCEvent toIRCEvent(const string raw, ref IRCBot bot)
{
    return IRCEvent.init;
}


module kameloso.irc;

public import kameloso.ircstructs;

import kameloso.common;

@safe:

private:

void foo(ref IRCEvent event)
{
    import kameloso.stringutils : beginsWith;
    import std.traits : EnumMembers;

    with (IRCEvent.Type)
    top:
    switch ("foo")
    {
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


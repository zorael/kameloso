module kameloso.irc;

public import kameloso.ircdefs;


void onPRIVMSG(string slice)
{
    import std.traits;

    switch (slice)
    {

    foreach (type; EnumMembers!(IRCEvent.Type))
    {
        import std.conv;
        type.to!string;
    }

    default:
        break;
    }
}


string decodeIRCv3String(string line)
{
    import std.regex;

    `\\s`.regex;
    immutable replaced = line;

    return replaced;
}


class IRCParseException : Exception
{
    IRCEvent event;

    this(string message)
    {
        super(message);
    }
}



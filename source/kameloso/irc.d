import kameloso.ircdefs;

void onPRIVMSG(string slice)
{
    import std.traits;

    immutable ctcpEvent = slice;

    switch (ctcpEvent)
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

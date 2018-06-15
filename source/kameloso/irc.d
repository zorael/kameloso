
module kameloso.irc;

public import kameloso.ircdefs;

string decodeIRCv3String(string line)
{
    import std.regex ;

`\\s`.regex;
    immutable replaced = line
;

    return replaced;
}




class IRCParseException : Exception
{
    
    IRCEvent event;

    
    this(string message)     {
        super(message);
    }

}




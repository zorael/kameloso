
module kameloso.irccolours;

private:

import dialect.common : IRCControlCharacter;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

version(Colours)
{
    import kameloso.terminal : TerminalBackground, TerminalForeground;
}

public:

@safe:


enum IRCColour
{
    unset       = -1,  
    white       = 0,   
    black       = 1,   
    blue        = 2,   
    green       = 3,   
    red         = 4,   
    brown       = 5,   
    purple      = 6,   
    orange      = 7,   
    yellow      = 8,   
    lightgreen  = 9,   
    cyan        = 10,  
    lightcyan   = 11,  
    lightblue   = 12,  
    pink        = 13,  
    grey        = 14,  
    lightgrey   = 15,  
    transparent = 99,  
}




void ircColourInto(Sink)
    (const string line,
    auto ref Sink sink,
    const IRCColour fg,
    const IRCColour bg = IRCColour.unset)
if (isOutputRange!(Sink, char[]))
in (line.length, "Tried to apply IRC colours to a string but no string was given")
{
    
}







string ircColour(const string line,
    const IRCColour fg,
    const IRCColour bg = IRCColour.unset) pure
in (line.length, "Tried to apply IRC colours to a string but no string was given")
{
    
    return string.init;
}







string ircColour(const IRCColour fg, const IRCColour bg = IRCColour.unset) pure
{
    import std.format : format;

    if (bg != IRCColour.unset)
    {
        return "%c%02d,%02d".format(cast(char)IRCControlCharacter.colour, fg, bg);
    }
    else
    {
        return "%c%02d".format(cast(char)IRCControlCharacter.colour, fg);
    }
}







string ircColourByHash(const string word) pure
in (word.length, "Tried to apply IRC colours by hash to a string but no string was given")
{
    
    return string.init;
}







string ircBold(T)(T something) 
{
    
    return string.init;
}







string ircItalics()(T something) 
{
    
    return string.init;
}







version(Colours)
string mapEffects(const string origLine,
    const uint fgBase = TerminalForeground.default_,
    const uint bgBase = TerminalBackground.default_) pure nothrow
{
    
    return string.init;
}







string stripEffects(const string line) pure nothrow
{
    
    return string.init;
}









module kameloso.common;

private:

import kameloso.logger : KamelosoLogger;
import dialect.defs : IRCClient, IRCServer;
import std.datetime.systime : SysTime;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;
import core.time : Duration, seconds;
static import kameloso.kameloso;

public:

@safe:

version(unittest)
shared static this()
{
    
    logger = new KamelosoLogger(No.monochrome, No.brightTerminal);

    
    settings = new kameloso.kameloso.CoreSettings;
}




KamelosoLogger logger;




void initLogger(const Flag!"monochrome" monochrome,
    const Flag!"brightTerminal" bright)
out (; (logger !is null), "Failed to initialise logger")
{
    import kameloso.logger : KamelosoLogger;
    logger = new KamelosoLogger(monochrome, bright);
    Tint.monochrome = monochrome;
}




kameloso.kameloso.CoreSettings* settings;




void printVersionInfo(const Flag!"colours" colours = Yes.colours) @safe
{
    
}




version(PrintStacktraces)
void printStacktrace() @system
{
    
}




struct OutgoingLine
{
    
    string line;

    
    bool quiet;

    
    this(const string line, const Flag!"quiet" quiet = No.quiet)
    {
        this.line = line;
        this.quiet = quiet;
    }
}




string[] findURLs(const string line) @safe pure
{
    

    string[] hits;
    

    return hits;
}







string timeSince(uint numUnits = 7, uint truncateUnits = 0)
    (const Duration duration,
    const Flag!"abbreviate" abbreviate = No.abbreviate,
    const Flag!"roundUp" roundUp = Yes.roundUp) pure
{
    
    return string.init;
}







string stripSeparatedPrefix(const string line,
    const string prefix,
    const Flag!"demandSeparatingChars" demandSep = Yes.demandSeparatingChars) pure @nogc
in (prefix.length, "Tried to strip separated prefix but no prefix was given")
{
    
    return string.init;
}







struct Tint
{
    
    static bool monochrome;

    version(Colours)
    {
        
        
        pragma(inline, true)
        static string opDispatch(string tint)()
        in ((logger !is null), "`Tint." ~ tint ~ "` was called with an uninitialised `logger`")
        {
            import std.traits : isSomeFunction;

            enum tintfun = "logger." ~ tint ~ "tint";

            static if (__traits(hasMember, logger, tint ~ "tint") &&
                isSomeFunction!(mixin(tintfun)))
            {
                return monochrome ? string.init : mixin(tintfun);
            }
            else
            {
                static assert(0, "Unknown tint `" ~ tint ~ "` passed to `Tint.opDispatch`");
            }
        }
    }
    else
    {
        
        pragma(inline, true)
        static string log()
        {
            return string.init;
        }

        alias all = log;
        alias info = log;
        alias warning = log;
        alias error = log;
        alias fatal = log;
        alias trace = log;
        alias off = log;
    }
}







string replaceTokens(const string line, const IRCClient client) @safe pure nothrow
{
    
    return string.init;
}







string replaceTokens(const string line) @safe pure nothrow
{
    
    return string.init;
}




SysTime nextMidnight(const SysTime now)
{
    
    return SysTime.init;
}







static immutable string[90] curlErrorStrings =
[
    0  : "ok",
];

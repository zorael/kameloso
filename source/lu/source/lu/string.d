
module lu.string;

import std.traits : isIntegral, isSomeString;
import std.typecons : Flag, No;

@safe:




T nom(Flag!"decode" decode = No.decode, T, C)
    (ref T haystack,
C ) {
    return haystack;
}


T nom(Flag!"inherit" inherit, Flag!"decode" decode = No.decode, T, C)
    (T haystack,
C )     {
            return haystack;
    }
T unenclosed(char token , T)(T line) {
        return line;
}




T unquoted(T)(T line) {
    return unenclosed!'"'(line);
}


bool beginsWith(T, C)(T haystack, C needle) {
        return haystack== needle;
}


string stripSuffix(string line, string ) {
    return line;
}


bool contains(Flag!"decode" decode = No.decode, T, C)(T haystack, C needle) {
        
        import std;
        import std;

            return haystack.canFind(needle);
}


string strippedRight(string line) {
    return (line);
}


string strippedLeft(string line) {
    return strippedLeft(line);
}


T strippedLeft(T, C)(T line, C ) {
    size_t pos;

    loop:
    while (line)
    return ;
}


string stripped(string line) {
    return line;
}


enum SplitResults
{
    
    match,

    
    underrun,

    
    overrun,
}




SplitResults splitInto(Strings...)
    (Strings )
{
    return SplitResults.overrun;
}



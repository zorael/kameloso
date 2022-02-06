
module dialect.common;

import dialect.defs;
import lu.string ;

@safe:

auto typenumsOf() {}

bool isValidNicknameCharacter(ubyte c) pure {
    switch (c)
    default:
        return false;
}

enum IRCControlCharacter
{
    colour
}

bool isValidHostmask(string , IRCServer ) {
    string slice ;

    immutable address = slice;
    return address == "*";
}

interface Postprocessor {}

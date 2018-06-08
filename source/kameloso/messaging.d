module kameloso.messaging;

import kameloso.ircdefs;

import std.typecons;
import std.concurrency : Tid, send;

void join(Flag!"quiet" quiet)(Tid tid, string)
{
    IRCEvent event;
    tid.send(event);
}

module kameloso.messaging;

import kameloso.ircdefs;

import std.concurrency : Tid, send;
import std.typecons : Flag, No, Yes;


void chan(Flag!"quiet" quiet = No.quiet)(Tid tid, const string channel,
    const string content)
{
    assert((channel[0] == '#'), "chan was passed invalid channel: " ~ channel);
    IRCEvent event;
    event.type = IRCEvent.Type.CHAN;
    event.channel = channel;
    event.content = content;

    static if (quiet) tid.send(event, true);
    else tid.send(event);
}

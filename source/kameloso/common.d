module kameloso.common;

import std.experimental.logger;

Logger logger;

void initLogger() {}

struct ThreadMessage
{
    struct PeekPlugins {}
}

struct CoreSettings {}

void printObjects(Things)(Things things)
{
    import std.stdio;

    formatObjectsImpl(stdout.lockingTextWriter, things);
}

void printObject(Thing)(Thing thing)
{
    printObjects(thing);
}

void formatObjectsImpl(Sink, Things...)(Sink sink, Things things)
{
    import std.format;

    foreach (thing; things)
    {
        foreach (member; thing.tupleof)
        {
            enum memberstring = __traits(identifier, thing);
            sink.formattedWrite(memberstring, member);
        }
    }
}

struct Client
{
    import kameloso.ircdefs;

    IRCBot bot;
}

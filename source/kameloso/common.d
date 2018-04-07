module kameloso.common;

import std.experimental.logger;
import std.typecons : Flag, Yes;

Logger logger;


void printObjects(uint widthArg, Things)(Things things)
{
    import std.stdio;
    formatObjectsImpl!widthArg(stdout.lockingTextWriter, things);
}


void printObject(uint widthArg = 0, Thing)(Thing thing)
{
    printObjects!widthArg(thing);
}


void formatObjectsImpl(uint widthArg , Sink, Things...)(Sink sink, Things things)
{
    import std.format;

    foreach (thing; things)
    {
        foreach (member; thing.tupleof)
        {
            sink.formattedWrite(string.init, member);
        }
    }
}

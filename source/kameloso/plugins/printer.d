module kameloso.plugins.printer;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.irc;

import std.stdio : writeln, writefln;
import std.array : Appender;


private:


IrcPluginState state;
Appender!(char[]) reusableAppender;  // Appender!string can't be cleared
enum appenderBufferSize = 600;  // longest length seen is 537


@(Label("any"))
@(IrcEvent.Type.ANY)
void onAnyEvent(const IrcEvent event)
{
    with (IrcEvent.Type)
    switch (event.type)
    {
    case RPL_NAMREPLY:
    case RPL_MOTD:
    case PING:
    case PONG:
    case SERVERINFO:
    case SERVERINFO_2:
    case RPL_LUSERCLIENT:
    case RPL_LUSEROP:
    case RPL_LUSERCHANNELS:
    case RPL_LUSERME:
    case RPL_LUSERUNKNOWN:
    case RPL_MOTDSTART:
    case RPL_ENDOFMOTD:
    case RPL_ENDOFNAMES:
    case USERCOUNTGLOBAL:
    case USERCOUNTLOCAL:
    case CONNECTIONRECORD:
        // These event types are too spammy; ignore
        break;

    default:
        import std.datetime;
        import std.conv : text;

        const timestamp = (cast(DateTime)SysTime.fromUnixTime(event.time)).timeOfDay.toString;

        //import std.format : formattedWrite;
        //app.formattedWrite("[%s] ", timestamp);
        // hot spot so let's optimize it a bit

        with (reusableAppender)
        {
            put('[');
            put(timestamp);
            put("] ");

            event.put(reusableAppender);

            writeln(data);
            reusableAppender.clear();
        }
    }
}


mixin basicEventHandlers;
mixin onEventImpl!__MODULE__;


public:

final class Printer : IrcPlugin
{
    mixin IrcPluginBasics;

    void initialise()
    {
        reusableAppender.reserve(appenderBufferSize);
    }
}

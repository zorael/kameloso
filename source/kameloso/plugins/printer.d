module kameloso.plugins.printer;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.array : Appender;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;


// reusableAppender
/+
 +  Appender to reuse as sink to fill when printing events.
 +
 +  It can't be Appender!string or it can't be cleared, so use Appender!(char[]).
 +  The content will be shortlived anyway so there's no risk of old lines creeping through.
 +  One workaround would be not to .clear() it, but to just set it to .init. However, the
 +  point of having a reusable Appender would be promptly lost.
 +/
Appender!(char[]) reusableAppender;

/// Longest length seen in the wild is 537, use a buffer slightly larger than that
enum appenderBufferSize = 600;


// onAnyEvent
/++
 +  Print an event to the local terminal.
 +
 +  Use the reusableAppender to slightly optimise the procedure by constantly reusing memory.
 +
 +  Params:
 +      event = the IrcEvent to print.
 +/
@Label("any")
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
    case TOPICSETTIME:
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


        /*  hot spot so let's optimize it a bit
            import std.format : formattedWrite;
            reusableAppender.formattedWrite("[%s] ", timestamp);
        */
        with (reusableAppender)
        {
            version(NoColours)
            {
                put('[');
                put(timestamp);
                put("] ");
            }
            else
            {
                put(colourise(Foreground.white));
                put('[');
                put(timestamp);
                put(']');
                put(colourise(Foreground.default_));
                put(" ");
            }

            event.put(reusableAppender);

            writeln(reusableAppender.data);

            reusableAppender.clear();
        }
    }
}


// initialise
/++
 +  Initialises the Printer plugin. Reserves space in the reusable Appenderk.
 +/
void initialise()
{
    reusableAppender.reserve(appenderBufferSize);
}


mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;

public:


// Printer
/++
 +  The Printer plugin takes all IrcEvents and prints them to the local terminal.
 +
 +  This used to be part of the core program, but with UDAs it's easy to split off into
 +  its own plugin.
 +/
final class Printer : IrcPlugin
{
    mixin IrcPluginBasics;
}

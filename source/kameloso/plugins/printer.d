module kameloso.plugins.printer;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.array : Appender;

private:

/// All plugin state variables gathered in a struct
IrcPluginState state;

Settings settings;
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
    case WHOISSECURECONN:
    case RPL_LUSERCLIENT:
    case RPL_LUSEROP:
    case RPL_LUSERCHANNELS:
    case RPL_LUSERME:
    case RPL_LUSERUNKNOWN:
    case RPL_WHOISSERVER:
    case RPL_ENDOFWHOIS:
    case RPL_MOTDSTART:
    case RPL_ENDOFMOTD:
    case RPL_ENDOFNAMES:
    case USERCOUNTGLOBAL:
    case USERCOUNTLOCAL:
    case CONNECTIONRECORD:
        // These event types are too spammy; ignore
        break;

    default:
        import std.conv : to;
        import std.datetime;
        import std.format : formattedWrite;

        const timestamp = (cast(DateTime)SysTime.fromUnixTime(event.time)).timeOfDay.toString;

        with (Foreground)
        with (event)
        with (reusableAppender)
        {
            if (state.settings.monochrome)
            {
                reusableAppender.formattedWrite("[%s] [%s] %s",
                    timestamp, type.to!string, sender);

                if (special)        reusableAppender.formattedWrite("*");
                if (target.length)  reusableAppender.formattedWrite(" (%s)",  target);
                if (channel.length) reusableAppender.formattedWrite(" [%s]",  channel);
                if (content.length) reusableAppender.formattedWrite(`: "%s"`, content);
                if (aux.length)     reusableAppender.formattedWrite(" <%s>",  aux);
                if (num > 0)        reusableAppender.formattedWrite(" (#%d)", num);
            }
            else
            {
                enum C
                {
                    type    = lightblue,
                    sender  = lightgreen,
                    special = lightyellow,
                    target  = cyan,
                    channel = yellow,
                    content = default_,
                    aux     = white,
                    num     = darkgrey,
                }

                Foreground senderColour = C.sender;

                if (state.settings.randomNickColours) // && (sender != state.bot.server.resolvedAddress))
                {
                    import std.traits : EnumMembers;

                    static immutable Foreground[17] foregrounds = [ EnumMembers!Foreground ];

                    auto colourIndex = hashOf(sender) % 16;
                    if (colourIndex == 1) colourIndex = 16;  // map black to white

                    senderColour = foregrounds[colourIndex];
                }

                Foreground typeColour = C.type;

                if (type == QUERY) typeColour = lightgreen;

                reusableAppender.formattedWrite("%s[%s]%s %s[%s]%s %s",
                    colourise(white), timestamp, colourise(default_),
                    colourise(typeColour), type.to!string,
                    colourise(senderColour), sender);

                if (special)        reusableAppender.formattedWrite("%s*",      colourise(C.special));
                if (target.length)  reusableAppender.formattedWrite(" %s(%s)",  colourise(C.target), target);
                if (channel.length) reusableAppender.formattedWrite(" %s[%s]",  colourise(C.channel), channel);
                if (content.length) reusableAppender.formattedWrite(`%s: "%s"`, colourise(C.content), content); // CHEATS
                if (aux.length)     reusableAppender.formattedWrite(" %s<%s>",  colourise(C.aux), aux);
                if (num > 0)        reusableAppender.formattedWrite(" %s(#%d)", colourise(C.num), num);

                reusableAppender.formattedWrite(colourise(Foreground.default_));
            }

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

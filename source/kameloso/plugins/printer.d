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
void onAnyEvent(const IrcEvent origEvent)
{
    IrcEvent event = origEvent; // need a mutable copy

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
                version (Colours)
                {
                    if (!state.settings.monochrome)
                    {
                        event.mapEffects();
                    }
                }

                enum DefaultColour
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

                Foreground senderColour = DefaultColour.sender;

                if (state.settings.randomNickColours) // && (sender != state.bot.server.resolvedAddress))
                {
                    import std.traits : EnumMembers;

                    static immutable Foreground[17] foregrounds = [ EnumMembers!Foreground ];

                    auto colourIndex = hashOf(sender) % 16;
                    if (colourIndex == 1) colourIndex = 16;  // map black to white

                    senderColour = foregrounds[colourIndex];
                }

                Foreground typeColour = DefaultColour.type;

                if (type == QUERY) typeColour = lightgreen;

                reusableAppender.formattedWrite("%s[%s]%s %s[%s]%s %s",
                    colourise(white), timestamp, colourise(default_),
                    colourise(typeColour), type.to!string,
                    colourise(senderColour), sender);

                if (special)        reusableAppender.formattedWrite("%s*",
                                        colourise(DefaultColour.special));
                if (target.length)  reusableAppender.formattedWrite(" %s(%s)",
                                        colourise(DefaultColour.target), target);
                if (channel.length) reusableAppender.formattedWrite(" %s[%s]",
                                        colourise(DefaultColour.channel), channel);
                if (content.length) reusableAppender.formattedWrite(`%s: "%s"`,
                                        colourise(DefaultColour.content), content); // CHEATS
                if (aux.length)     reusableAppender.formattedWrite(" %s<%s>",
                                        colourise(DefaultColour.aux), aux);
                if (num > 0)        reusableAppender.formattedWrite(" %s(#%d)",
                                        colourise(DefaultColour.num), num);

                reusableAppender.formattedWrite(colourise(Foreground.default_));
            }

            writeln(reusableAppender.data);
            reusableAppender.clear();
        }
    }
}


version (Colours)
void mapEffects(ref IrcEvent event)
{
    import std.string : representation;
    import std.algorithm.searching : canFind;

    alias I = IrcControlCharacter;
    alias B = BashEffectToken;

    if (event.content.representation.canFind(I.colour))
    {
        // Colour is mIRC 3
        event.mapColours();
    }

    if (event.content.representation.canFind(I.bold))
    {
        // Bold is bash 1, mIRC 2
        event.mapEffectImpl!(B.bold, I.bold)();
    }

    if (event.content.representation.canFind(I.italics))
    {
        // Italics is bash 3 (not really), mIRC 29
        event.mapEffectImpl!(B.italics, I.italics)();
    }

    if (event.content.representation.canFind(I.underlined))
    {
        // Underlined is bash 4, mIRC 31
        event.mapEffectImpl!(B.underlined, I.underlined)();
    }
}


version (Colours)
void mapColours(ref IrcEvent event)
{
    import std.regex;

    enum colourPattern = 3 ~ "([0-9]{1,2})(?:,([0-9]{1,2}))?";
    static engine = ctRegex!colourPattern;

    /*alias F = Foreground;
    Foreground[16] colourMap = // literal map
    [
         0 : F.white,
         1 : F.black,
         2 : F.blue,
         3 : F.green,
         4 : F.lightred,
         5 : F.darkgrey,  // should be brown
         6 : F.magenta,
         7 : F.yellow,
         8 : F.lightyellow,
         9 : F.lightgreen,
        10 : F.cyan,
        11 : F.lightcyan,
        12 : F.lightblue,
        13 : F.lightmagenta,
        14 : F.default_,
        15 : F.lightgrey,
    ];*/

    alias F = Foreground;
    Foreground[16] weechatMap =
    [
         0 : F.white,
         1 : F.darkgrey,
         2 : F.lightblue,
         3 : F.lightgreen,
         4 : F.lightred,
         5 : F.lightred,
         6 : F.magenta,
         7 : F.lightyellow,
         8 : F.lightyellow,
         9 : F.lightgreen,
        10 : F.lightcyan,
        11 : F.lightcyan,
        12 : F.lightblue,
        13 : F.lightmagenta,
        14 : F.darkgrey,
        15 : F.white,
    ];

    immutable originalContent = event.content;

    foreach (hit; originalContent.matchAll(engine))
    {
        import std.conv : to;

        immutable index = hit[1].to!size_t;

        if (index > 15)
        {
            writeln("mIRC colour code out of bounds: ", index);
            continue;
        }

        immutable bashColourCode = weechatMap[index];
        string bashColourToken = "\033[" ~ bashColourCode ~ "m";

        event.content = event.content.replaceAll(hit[0].regex, bashColourToken);
    }

    event.content ~= "\033[0m";
}

version (Colours)
void mapEffectImpl(ubyte bashEffectCode, ubyte mircToken)(ref IrcEvent event)
{
    import std.regex;
    import std.conv : to;

    static engine = ctRegex!([cast(char)mircToken]);
    enum bashToken = "\033[" ~ bashEffectCode.to!string ~ "m";

    event.content = event.content.replaceAll(engine, bashToken);
    event.content ~= "\033[0m";
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

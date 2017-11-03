module kameloso.plugins.printer;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.array : Appender;
import std.stdio;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

/// Runtime settings for bot behaviour
Settings settings;


// reusableAppender
/++
 +  Appender to reuse as sink to fill when printing events.
 +
 +  It can't be Appender!string or it can't be cleared, so use Appender!(char[]).
 +  The content will be shortlived anyway so there's no risk of old lines
 +  creeping through. One workaround would be not to .clear() it, but to just
 +  set it to .init. However, the point of having a reusable Appender would be
 +  promptly lost.
 +/
Appender!(char[]) reusableAppender;


/// Appender buffer size. Longest length seen in the wild is 537, use a buffer
/// slightly larger than that.
enum appenderBufferSize = 600;


// onAnyEvent
/++
 +  Print an event to the local terminal.
 +
 +  Use the reusableAppender to slightly optimise the procedure by constantly
 +  reusing memory.
 +
 +  Params:
 +      event = the IRCEvent to print.
 +/
@Label("any")
@(IRCEvent.Type.ANY)
void onAnyEvent(const IRCEvent origEvent)
{
    IRCEvent event = origEvent; // need a mutable copy

    with (IRCEvent)
    with (IRCEvent.Type)
    switch (event.type)
    {
    case RPL_NAMREPLY:
    case RPL_MOTD:
    case PING:
    case PONG:
    case SERVERINFO:
    case RPL_ISUPPORT:
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
    // case CAP:
        // These event types are too spammy; ignore
        break;

    default:
        reusableAppender.formatMessage(event);
        writeln(reusableAppender.data);
        reusableAppender.clear();
    }
}


void formatMessage(Sink)(auto ref Sink sink, IRCEvent event)
{
    import std.conv : to;
    import std.datetime;
    import std.format : formattedWrite;
    import std.range : put;

    immutable timestamp = (cast(DateTime)SysTime.fromUnixTime(event.time))
                            .timeOfDay
                            .toString();

    with (Foreground)
    with (event)
    if (state.settings.monochrome)
    {

        sink.formattedWrite("[%s] [%s] ",
            timestamp, type.to!string);

        sink.put(sender);//put(sink, sender);

        if (special)        sink.put('*');
        if (role != Role.init)
                            sink.formattedWrite(" [%s]", role.to!string);
        if (alias_.length && (alias_ != sender))
                            sink.formattedWrite(" (%s)", alias_);
        if (target.length)  sink.formattedWrite(" (%s)",  target);
        if (channel.length) sink.formattedWrite(" [%s]",  channel);
        if (content.length) sink.formattedWrite(`: "%s"`, content);
        if (aux.length)     sink.formattedWrite(" <%s>",  aux);
        if (num > 0)        sink.formattedWrite(" (#%d)", num);
    }
    else
    {
        version(Colours)
        {
            if (!state.settings.monochrome) event.mapEffects();
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

        if (state.settings.randomNickColours)
        {
            import std.traits : EnumMembers;

            static immutable Foreground[17] fg = [ EnumMembers!Foreground ];

            auto colourIndex = hashOf(sender) % 16;
            if (colourIndex == 1) colourIndex = 16;  // map black to white
            senderColour = fg[colourIndex];
        }

        Foreground typeColour = DefaultColour.type;
        if (type == IRCEvent.Type.QUERY) typeColour = lightgreen;

        sink.formattedWrite!"%s[%s] %s[%s] "
            (colourise(white), timestamp, colourise(typeColour), type.to!string);

        import std.string : toLower;

        bool aliasPrinted;

        if (alias_.length && (sender == alias_.toLower))
        {
            put(sink, colourise(senderColour));
            put(sink, alias_);
            aliasPrinted = true;
        }
        else
        {
            put(sink, colourise(senderColour));
            put(sink, sender);
        }

        if (special)        sink.formattedWrite("%s*",
                                colourise(DefaultColour.special));
        if (role != Role.init) sink.formattedWrite(" %s[%s]",
                                colourise(DefaultColour.white),
                                role.to!string);
        if (!aliasPrinted && alias_.length && (alias_ != sender))
                            sink.formattedWrite(" %s(%s)",
                                colourise(senderColour), alias_);
        if (target.length)  sink.formattedWrite(" %s(%s)",
                                colourise(DefaultColour.target), target);
        if (channel.length) sink.formattedWrite(" %s[%s]",
                                colourise(DefaultColour.channel), channel);
        if (content.length) sink.formattedWrite(`%s: "%s"`,
                                colourise(DefaultColour.content), content);
        if (aux.length)     sink.formattedWrite(" %s<%s>",
                                colourise(DefaultColour.aux), aux);
        if (num > 0)        sink.formattedWrite(" %s(#%d)",
                                colourise(DefaultColour.num), num);

        sink.formattedWrite(colourise(Foreground.default_));
    }
}


// mapEffects
/++
 +  Map mIRC effect tokens (colour, bold, italics, underlined) to Bash ones.
 +
 +  Params:
 +      ref event = the IRCEvent to modify for printing.
 +/
version(Colours)
void mapEffects(ref IRCEvent event)
{
    import std.algorithm.searching : canFind;
    import std.string : representation;

    alias I = IRCControlCharacter;
    alias B = BashEffectToken;

    immutable lineBytes = event.content.representation;

    if (lineBytes.canFind(cast(ubyte)I.colour))
    {
        // Colour is mIRC 3
        event.mapColours();
    }

    if (lineBytes.canFind(cast(ubyte)I.bold))
    {
        // Bold is bash 1, mIRC 2
        event.mapEffectImpl!(cast(ubyte)B.bold, cast(ubyte)I.bold)();
    }

    if (lineBytes.canFind(cast(ubyte)I.italics))
    {
        // Italics is bash 3 (not really), mIRC 29
        event.mapEffectImpl!(cast(ubyte)B.italics, cast(ubyte)I.italics)();
    }

    if (lineBytes.canFind(cast(ubyte)I.underlined))
    {
        // Underlined is bash 4, mIRC 31
        event.mapEffectImpl!(cast(ubyte)B.underlined, cast(ubyte)I.underlined)();
    }
}


// mapColours
/++
 +  Map mIRC effect color tokens to Bash ones.
 +
 +  Params:
 +      ref event = the IRCEvent to modify for printing.
 +/
version(Colours)
void mapColours(ref IRCEvent event)
{
    import std.regex;

    enum colourPattern = 3 ~ "([0-9]{1,2})(?:,([0-9]{1,2}))?";
    static engine = ctRegex!colourPattern;

    alias F = Foreground;
    Foreground[16] weechatForegroundMap =
    [
         0 : F.white,
         1 : F.darkgrey,
         2 : F.blue,
         3 : F.green,
         4 : F.lightred,
         5 : F.red,
         6 : F.magenta,
         7 : F.yellow,
         8 : F.lightyellow,
         9 : F.lightgreen,
        10 : F.cyan,
        11 : F.lightcyan,
        12 : F.lightblue,
        13 : F.lightmagenta,
        14 : F.darkgrey,
        15 : F.lightgrey,
    ];

    alias B = Background;
    Background[16] weechatBackgroundMap =
    [
         0 : B.white,
         1 : B.black,
         2 : B.blue,
         3 : B.green,
         4 : B.red,
         5 : B.red,
         6 : B.magenta,
         7 : B.yellow,
         8 : B.yellow,
         9 : B.green,
        10 : B.cyan,
        11 : B.cyan,
        12 : B.blue,
        13 : B.magenta,
        14 : B.black,
        15 : B.lightgrey,
    ];

    immutable originalContent = event.content;

    foreach (hit; originalContent.matchAll(engine))
    {
        import std.conv : to;

        if (!hit[1].length) continue;

        Appender!string colourToken;
        colourToken.reserve(8);
        immutable fgIndex = hit[1].to!size_t;

        if (fgIndex > 15)
        {
            logger.warning("mIRC foreground colour code out of bounds: ",
                           fgIndex);
            continue;
        }

        colourToken ~= "\033[";
        colourToken ~= cast(string)weechatForegroundMap[fgIndex];

        if (hit[2].length)
        {
            immutable bgIndex = hit[2].to!size_t;

            if (bgIndex > 15)
            {
                logger.warning("mIRC background colour code out of bounds: ",
                               bgIndex);
                continue;
            }

            colourToken ~= ';';
            colourToken ~= cast(string)weechatBackgroundMap[bgIndex];
        }

        colourToken ~= 'm';
        event.content = event.content.replaceAll(hit[0].regex, colourToken.data);
    }

    event.content ~= "\033[0m";
}

version(Colours)
void mapEffectImpl(ubyte bashEffectCode, ubyte mircToken)(ref IRCEvent event)
{
    import std.conv  : to;
    import std.regex : ctRegex, replaceAll;

    static engine = ctRegex!([cast(char)mircToken]);
    enum bashToken = "\033[" ~ bashEffectCode.to!string ~ "m";

    event.content = event.content.replaceAll(engine, bashToken);
    event.content ~= "\033[0m";
}


// initialise
/++
 +  Initialises the Printer plugin. Reserves space in the reusable Appender.
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
 +  The Printer plugin takes all IRCEvents and prints them to the local terminal.
 +
 +  This used to be part of the core program, but with UDAs it's easy to split
 +  off into its own plugin.
 +/
final class Printer : IRCPlugin
{
    mixin IRCPluginBasics;
}

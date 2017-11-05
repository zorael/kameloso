module kameloso.plugins.printer;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.array : Appender;
import std.stdio;

private:

struct PrinterOptions
{
    bool monochrome;
    bool randomNickColours = true;
}

/// All Printer plugin options gathered
PrinterOptions printerOptions;

/// All plugin state variables gathered in a struct
IRCPluginState state;

// onAnyEvent
/++
 +  Print an event to the local terminal.
 +
 +  Write directly to a LockingTextWriter.
 +
 +  Params:
 +      event = the IRCEvent to print.
 +/
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
        formatMessage(stdout.lockingTextWriter, event);
        break;
    }
}


void formatMessage(Sink)(auto ref Sink sink, IRCEvent event)
{
    import kameloso.stringutils : enumToString;

    import std.datetime;
    import std.format : formattedWrite;
    import std.string : toLower;

    immutable timestamp = (cast(DateTime)SysTime.fromUnixTime(event.time))
                            .timeOfDay
                            .toString();

    with (BashForeground)
    with (event)
    if (printerOptions.monochrome)
    {
        sink.formattedWrite("[%s] [%s] ",
            timestamp, enumToString(type));

        sink.put(sender);

        if (special)        sink.put('*');
        if (role != Role.init)
                            sink.formattedWrite(" [%s]", enumToString(role));
        if (alias_.length && (sender != alias_.toLower))
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
            if (!printerOptions.monochrome) event.mapEffects();
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

        BashForeground senderColour = DefaultColour.sender;

        if (printerOptions.randomNickColours)
        {
            import std.traits : EnumMembers;

            static immutable BashForeground[17] fg = [ EnumMembers!BashForeground ];

            auto colourIndex = hashOf(sender) % 16;
            if (colourIndex == 1) colourIndex = 16;  // map black to white
            senderColour = fg[colourIndex];
        }

        BashForeground typeColour = DefaultColour.type;
        if (type == IRCEvent.Type.QUERY) typeColour = lightgreen;

        sink.colourise(white);
        sink.formattedWrite("[%s] ", timestamp);
        sink.colourise(typeColour);
        sink.formattedWrite("[%s] ", enumToString(type));  // typestring?

        bool aliasPrinted;

        if (alias_.length && (sender == alias_.toLower))
        {
            sink.colourise(senderColour);
            sink.put(alias_);
            aliasPrinted = true;
        }
        else
        {
            sink.colourise(senderColour);
            sink.put(sender);
        }

        if (special)
        {
            sink.colourise(DefaultColour.special);
            sink.put('*');
        }

        if (role != Role.init)
        {
            sink.colourise(white);
            sink.formattedWrite(" [%s]", enumToString(role));
        }

        if (!aliasPrinted && alias_.length && (alias_ != sender))
        {
            sink.colourise(senderColour);
            sink.formattedWrite(" (%s)", alias_);
        }

        if (target.length)
        {
            sink.colourise(DefaultColour.target);
            sink.formattedWrite(" (%s)", target);
        }

        if (channel.length)
        {
            sink.colourise(DefaultColour.channel);
            sink.formattedWrite(" [%s]", channel);
        }

        if (content.length)
        {
            sink.colourise(DefaultColour.content);
            sink.formattedWrite(`: "%s"`, content);
        }

        if (aux.length)
        {
            sink.colourise(DefaultColour.aux);
            sink.formattedWrite(" <%s>", aux);
        }

        if (num > 0)
        {
            sink.colourise(DefaultColour.num);
            sink.formattedWrite(" (#%d)", num);
        }

        sink.colourise(default_);

        static if (!__traits(hasMember, Sink, "data"))
        {
            sink.put('\n');
        }
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

    alias F = BashForeground;
    BashForeground[16] weechatForegroundMap =
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

    alias B = BashBackground;
    BashBackground[16] weechatBackgroundMap =
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

        Appender!string sink;
        sink.reserve(8);

        immutable fgIndex = hit[1].to!size_t;

        if (fgIndex > 15)
        {
            logger.warning("mIRC foreground colour code out of bounds: ",
                           fgIndex);
            continue;
        }

        sink.put("\033[");
        sink.put(cast(string)weechatForegroundMap[fgIndex]);

        if (hit[2].length)
        {
            immutable bgIndex = hit[2].to!size_t;

            if (bgIndex > 15)
            {
                logger.warning("mIRC background colour code out of bounds: ",
                               bgIndex);
                continue;
            }

            sink.put(';');
            sink.put(cast(string)weechatBackgroundMap[bgIndex]);
        }

        sink.put('m');
        event.content = event.content.replaceAll(hit[0].regex, sink.data);
    }

    //event.content ~= "\033[0m";
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

void loadConfig(const string configFile)
{
    import kameloso.config : readConfig;
    configFile.readConfig(printerOptions);
}

void writeConfig(const string configFile)
{
    import kameloso.config : replaceConfig;
    configFile.replaceConfig(printerOptions);
}

void present()
{
    printObject(printerOptions);
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

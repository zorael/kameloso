module kameloso.plugins.printer;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;

import std.array : Appender;
import std.stdio;

private:


/// All Printer plugin options gathered in a struct
struct PrinterOptions
{
    version(Windows)
    {
        bool monochrome = true;
    }
    else
    {
        bool monochrome = false;
    }

    bool truecolour = true;
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


// put
/++
 +  Puts a variadic list of values into an output range sink.
 +
 +  Params:
 +      sink = output range to sink items into
 +      args = variadic list of things to put
 +/
void put(Sink, Args...)(auto ref Sink sink, Args args)
{
    static import std.range;
    import std.conv : to;

    foreach (arg; args)
    {
        static if (!__traits(compiles, std.range.put(sink, typeof(arg).init)))
        {
            std.range.put(sink, arg.to!string);
        }
        else
        {
            std.range.put(sink, arg);
        }
    }
}


// formatMessage
/++
 +  Formats an IRCEvent into an output range sink.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  By default output is in colours, unless on Windows. The behaviour is stored
 +  and read from the PrinterOptions struct.
 +
 +  Params:
 +      sink = output range to format the IRCEvent into
 +      event = the reference event that is being formatted
 +/
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
        import std.algorithm : equal;
        import std.uni : asLowerCase;

        sink.formattedWrite("[%s] [%s] ",
            timestamp, enumToString(type));

        sink.put((alias_.length && alias_.asLowerCase.equal(sender)) ?
            alias_ : sender);

        if (special)
        {
            sink.put('*');
        }

        if (role != Role.init)
        {
            sink.formattedWrite(" [%s]", enumToString(role));
        }

        if (alias_.length && (alias_ != sender))
        {
            sink.formattedWrite(" (%s)", alias_);
        }

        if (target.length)  sink.formattedWrite(" (%s)",  target);
        if (channel.length) sink.formattedWrite(" [%s]",  channel);
        if (content.length) sink.formattedWrite(`: "%s"`, content);
        if (aux.length)     sink.formattedWrite(" <%s>",  aux);
        if (num > 0)        sink.formattedWrite(" (#%d)", num);

        static if (!__traits(hasMember, Sink, "data"))
        {
            sink.put('\n');
        }
    }
    else
    {
        version(Colours)
        {
            event.mapEffects();

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

            static BashForeground colourByHash(const string nickname)
            {
                if (printerOptions.randomNickColours)
                {
                    import std.traits : EnumMembers;

                    static immutable BashForeground[17] fg =
                        [ EnumMembers!BashForeground ];

                    auto colourIndex = hashOf(nickname) % 16;
                    if (colourIndex == 1) colourIndex = 16;  // map black to white
                    return fg[colourIndex];
                }

                // fixme
                return DefaultColour.sender;
            }

            void colouriseSenderTruecolour()
            {
                if (event.colour.length && printerOptions.truecolour)
                {
                    import kameloso.stringutils : numFromHex;

                    int r, g, b;
                    event.colour.numFromHex(r, g, b);
                    sink.truecolourise(r, g, b);
                }
                else
                {
                    sink.colourise(colourByHash(sender));
                }
            }

            BashForeground typeColour = (type == IRCEvent.Type.QUERY) ?
                lightgreen : DefaultColour.type;

            sink.colourise(white);
            //sink.formattedWrite("[%s] ", timestamp);
            put(sink, '[', timestamp, "] ");
            sink.colourise(typeColour);
            //sink.formattedWrite("[%s] ", enumToString(type));  // typestring?
            put(sink, '[', enumToString(type), "] ");

            import std.algorithm : equal;
            import std.uni : asLowerCase;

            bool aliasPrinted;

            colouriseSenderTruecolour();

            if (alias_.length && alias_.asLowerCase.equal(sender))
            {
                sink.put(alias_);
                aliasPrinted = true;
            }
            else
            {
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

            if (alias_.length && !aliasPrinted)
            {
                colouriseSenderTruecolour();
                //sink.formattedWrite(" (%s)", alias_);
                put(sink, " (", alias_, ')');
            }

            if (target.length)
            {
                if (target[0] == '#')
                {
                    // Let all channels be one colour
                    sink.colourise(DefaultColour.target);
                }
                else
                {
                    sink.colourise(colourByHash(event.target));
                }

                //sink.formattedWrite(" (%s)", target);
                put(sink, " (", target, ')');
            }

            if (channel.length)
            {
                sink.colourise(DefaultColour.channel);
                //sink.formattedWrite(" [%s]", channel);
                put(sink, " [", channel, ']');
            }

            if (content.length)
            {
                sink.colourise(DefaultColour.content);
                //sink.formattedWrite(`: "%s"`, content);
                put(sink, `: "`, content, '"');
            }

            if (aux.length)
            {
                sink.colourise(DefaultColour.aux);
                //sink.formattedWrite(" <%s>", aux);
                put(sink, " <", aux, '>');
            }

            if (num > 0)
            {
                sink.colourise(DefaultColour.num);
                //sink.formattedWrite(" (#%d)", num);
                put(sink, " (#", num, ')');
            }

            sink.colourise(default_);

            static if (!__traits(hasMember, Sink, "data"))
            {
                sink.put('\n');
            }
        }
        else
        {
            logger.warning("bot was not built with colour support yet " ~
                "monochrome is off; forcing monochrome.");

            printerOptions.monochrome = true;
            return formatMessage(sink, event);
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
        event.mapAlternatingEffectImpl!(B.bold, I.bold)();
    }

    if (lineBytes.canFind(cast(ubyte)I.italics))
    {
        // Italics is bash 3 (not really), mIRC 29
        event.mapAlternatingEffectImpl!(B.italics, I.italics)();
    }

    if (lineBytes.canFind(cast(ubyte)I.underlined))
    {
        // Underlined is bash 4, mIRC 31
        event.mapAlternatingEffectImpl!(B.underlined, I.underlined)();
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
        sink.put((cast(size_t)weechatForegroundMap[fgIndex]).to!string);

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
            sink.put((cast(size_t)weechatBackgroundMap[bgIndex]).to!string);
        }

        sink.put('m');
        event.content = event.content.replaceAll(hit[0].regex, sink.data);
    }

    //event.content ~= "\033[0m";
}


// mapAlternatingEffectImpl
/++
 +  Replaces mIRC tokens with Bash effect codes, in an alternating fashion so as
 +  to support repeated effects toggling behaviour.
 +
 +  It seems to be the case that a token for bold text will trigger bold text up
 +  until the next bold token. If we only naïvely replace all mIRC tokens for
 +  bold text then, we'll get lines that start off bold and continue as such
 +  until the very end.
 +
 +  Instead we look at it in a pairwise perspective. We use regex to replace
 +  pairs of tokens, properly alternating and toggling on and off, then once
 +  more at the end in case there was an odd token only toggling on.
 +
 +  Params:
 +      bashEffectCode = the Bash equivalent of the mircToken effect
 +      mircToken = the mIRC token for a particular text effect
 +      ref event = the IRC event whose content body to work on
 +/
version(Colours)
void mapAlternatingEffectImpl(ubyte bashEffectCode, ubyte mircToken)
    (ref IRCEvent event)
{
    import std.array : Appender;
    import std.conv  : to;
    import std.regex : ctRegex, matchAll, replaceAll;

    enum bashToken = "\033[" ~ (cast(ubyte)bashEffectCode).to!string ~ "m";

    enum pattern = "(?:"~mircToken~")([^"~mircToken~"]*)(?:"~mircToken~")";
    static immutable engine = ctRegex!pattern;

    Appender!string sink;
    sink.reserve(cast(size_t)(event.content.length * 1.1));

    auto hits = event.content.matchAll(pattern);

    while (hits.front.length)
    {
        sink.put(hits.front.pre);
        sink.put(bashToken);
        sink.put(hits.front[1]);

        switch (bashEffectCode)
        {
        case 1:
        case 2:
            // Both 1 and 2 seem to be reset by 22?
            sink.put("\033[22m");
            break;

        case 3:
        ..
        case 5:
            sink.put("\033[2" ~ bashEffectCode.to!string ~ "m");
            break;

        default:
            logger.warning("Unknown Bash effect code: ", bashEffectCode);
            sink.put("\033[0m");
            break;
        }

        hits = hits.post.matchAll(pattern);
    }

    // We've gone through them pair-wise, now see if there are any singles left
    static singleTokenEngine = ctRegex!([cast(char)mircToken]);
    sink.put(hits.post.replaceAll(singleTokenEngine, bashToken));

    // End tags and commit
    sink.put("\033[0m");
    event.content = sink.data;
}

unittest
{
    import std.conv : to;

    alias I = IRCControlCharacter;
    alias B = BashEffectToken;

    enum bBold = "\033[" ~ (cast(ubyte)B.bold).to!string ~ "m";
    enum bReset = "\033[22m";
    enum bResetAll = "\033[0m";

    string line1 = "ABC"~I.bold~"DEF"~I.bold~"GHI"~I.bold~"JKL"~I.bold~"MNO";
    string line2 = "ABC"~bBold~"DEF"~bReset~"GHI"~bBold~"JKL"~bReset~"MNO"~bResetAll;

    IRCEvent event;
    event.content = line1;
    event.mapEffects();
    assert((event.content == line2), line1);
}


void loadConfig(const string configFile)
{
    import kameloso.config2 : readConfig;
    configFile.readConfig(printerOptions);
}


void addToConfig(ref Appender!string sink)
{
    import kameloso.config2;
    sink.serialise(printerOptions);
}

void present()
{
    printObject(printerOptions);
}


public:

mixin BasicEventHandlers;
mixin OnEventImpl!__MODULE__;


// Printer
/++
 +  The Printer plugin takes all IRCEvents and prints them to the local terminal.
 +
 +  This used to be part of the core program, but with UDAs it's easy to split
 +  off into its own plugin.
 +/
final class PrinterPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}

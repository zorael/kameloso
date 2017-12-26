module kameloso.plugins.printer;

import kameloso.plugins.common;
import kameloso.ircdefs;
import kameloso.common;

import std.typecons : No, Yes;
import std.stdio;

private:


// PrinterSettings
/++
 +  All Printer plugin options gathered in a struct
 +
 +  ------------
 +  struct PrinterSettings
 +  {
 +      bool truecolor = true;
 +      bool normaliseTrueclour = true;
 +      bool randomNickColours = true;
 +      bool filterVerbose = true;
 +      bool badgesInCaps = false;
 +      bool typesInCaps = true;
 +  }
 +  ------------
 +/
struct PrinterSettings
{
    /// Flag to display advanced colours in RRGGBB rather than simple Bash
    bool truecolour = true;

    /// Flag to normalise truecolours; make dark brighter and bright darker
    bool normaliseTruecolour = true;

    /// Flag to display nicks in random colour based on their nickname hash
    bool randomNickColours = true;

    /// Flag to filter away most uninteresting events
    bool filterVerbose = true;

    /// Flag to print the badge field in caps (as they used to be earlier)
    bool badgesInCaps = false;

    /// Flag to send a terminal bell signal when the bot is mentioned in chat.
    bool bellOnMention = true;

    /// Flag to have the type names be in capital letters.
    bool typesInCaps = true;
}


// onAnyEvent
/++
 +  Print an event to the local terminal.
 +
 +  Does not allocate, writes directly to a `LockingTextWriter`.
 +/
@(Chainable)
@(IRCEvent.Type.ANY)
@(ChannelPolicy.any)
void onAnyEvent(PrinterPlugin plugin, const IRCEvent event)
{
    IRCEvent mutEvent = event; // need a mutable copy

    with (IRCEvent.Type)
    switch (event.type)
    {
    case RPL_NAMREPLY:
    case RPL_MOTD:
    case RPL_YOURHOST:
    case RPL_ISUPPORT:
    case RPL_TOPICWHOTIME:
    case RPL_WHOISSECURE:
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
    case RPL_GLOBALUSERS:
    case RPL_LOCALUSERS:
    case RPL_STATSCONN:
    case RPL_CREATED:
    case RPL_MYINFO:
    case RPL_ENDOFWHO:
    case RPL_WHOREPLY:
    case CAP:
        // These event types are too spammy; ignore
        if (!plugin.printerSettings.filterVerbose) goto default;
        break;

    case PING:
    case PONG:
        break;

    default:
        plugin.formatMessage(stdout.lockingTextWriter, mutEvent, settings.monochrome);
        version(Cygwin_) stdout.flush();
        break;
    }
}


// onWelcome
/++
 +  After connect, record whether the bot's nickname has an elaborate boundary,
 +  so we don't check it every single time we try to invert it and send a bell
 +  (on mention).
 +
 +  It doesn't have to be `RPL_WELCOME` but it's as good a choice as any.
 +/
@(IRCEvent.Type.RPL_WELCOME)
void onWelcome(PrinterPlugin plugin)
{
    plugin.nicknameHasElaborateBoundary = plugin.state.bot.nickname.hasElaborateBoundary;
}


// onSELFNICK
/++
 +  Reevaluate whether the bot's nickname has an elaborate boundary upon nick
 +  change.
 +/
@(IRCEvent.Type.SELFNICK)
void onSELFNICK(PrinterPlugin plugin, const IRCEvent event)
{
    plugin.nicknameHasElaborateBoundary = event.target.nickname.hasElaborateBoundary;
}


// hasElaborateBoundary
/++
 +  Determine whether the bot's nickname has an elaborate boundary.
 +
 +  An elaborate boundary is when the bot's nickname ends with a sign, or any
 +  non-word character, such as `kameloso^`. We need to know this when we're
 +  trying to highlight the bot being mentioned in chat; we use a different
 +  regex if the nickname ends with something weird, and another for normal
 +  nicks. There will be false positves if we don't differentiate between them.
 +/
bool hasElaborateBoundary(const string nickname)
{
    import std.regex : ctRegex, matchAll;

    static boundaryEngine = ctRegex!r"^.*?[\W0-9_-]$";

    return !nickname.matchAll(boundaryEngine).empty;
}

///
unittest
{
    import std.conv : text;

    {
        immutable b = "kameloso".hasElaborateBoundary;
        assert((b == false), b.text);
    }

    {
        immutable b = "kameloso^".hasElaborateBoundary;
        assert((b == true), b.text);
    }

    {
        immutable b = "kameloso`".hasElaborateBoundary;
        assert((b == true), b.text);
    }

    {
        immutable b = "kameloso123".hasElaborateBoundary;
        assert((b == true), b.text);
    }

    {
        immutable b = "kameloso_".hasElaborateBoundary;
        assert((b == true), b.text);
    }

    {
        immutable b = "kameloso-".hasElaborateBoundary;
        assert((b == true), b.text);
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
    import std.range : put;
    import std.conv : to;

    foreach (arg; args)
    {
        static if (!__traits(compiles, std.range.put(sink, typeof(arg).init)))
        {
            put(sink, arg.to!string);
        }
        else
        {
            put(sink, arg);
        }
    }
}


// formatMessage
/++
 +  Formats an `IRCEvent` into an output range sink.
 +
 +  It formats the timestamp, the type of the event, the sender or sender alias,
 +  the channel or target, the content body, as well as auxiliary information.
 +
 +  By default output is in colours, unless on Windows. The behaviour is stored
 +  and read from the `printerSettings` struct.
 +
 +  Params:
 +      sink = output range to format the IRCEvent into
 +      event = the reference event that is being formatted
 +/
void formatMessage(Sink)(PrinterPlugin plugin, auto ref Sink sink, IRCEvent event,
    bool monochrome)
{
    import kameloso.bash : BashForeground;
    import kameloso.string : enumToString, beginsWith;
    import std.algorithm : equal;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.string : toLower;
    import std.uni : asLowerCase;

    immutable timestamp = (cast(DateTime)SysTime
        .fromUnixTime(event.time))
        .timeOfDay
        .toString();

    with (BashForeground)
    with (plugin.state)
    with (event)
    with (event.sender)
    if (monochrome)
    {
        put(sink, '[', timestamp, "] ");

        string typestring = plugin.printerSettings.typesInCaps ?
            enumToString(type) : enumToString(type).toLower;

        if (typestring.beginsWith("RPL_") || typestring.beginsWith("rpl_") ||
            typestring.beginsWith("ERR_") || typestring.beginsWith("err_"))
        {
            typestring = typestring[4..$];
        }

        put(sink, '[', typestring, "] ");

        bool aliasPrinted;

        if (sender.isServer)
        {
            sink.put(address);
        }
        else
        {
            if (alias_.length && alias_.asLowerCase.equal(nickname))
            {
                sink.put(alias_);
                aliasPrinted = true;
            }
            else
            {
                sink.put(nickname);
            }

            if (special)
            {
                sink.put('*');
            }
        }

        if (badge.length)
        {
            import std.string : toUpper;

            immutable badgestring = plugin.printerSettings.badgesInCaps ?
                badge.toUpper : badge;

            put(sink, " [", badgestring, ']');
        }

        if (!sender.isServer && alias_.length && !aliasPrinted)
        {
            put(sink, " (", alias_, ')');
        }

        if (target.nickname.length) put(sink, " (", target.nickname, ')');
        if (channel.length)         put(sink, " [", channel, ']');

        if (content.length)
        {
            if (sender.isServer || nickname.length)
            {
                import std.algorithm.searching : canFind;

                with (IRCEvent.Type)
                switch (type)
                {
                case CHAN:
                case QUERY:
                    if ((cast(ubyte[])event.content)
                        .canFind(cast(ubyte[])bot.nickname))
                    {
                        // Nick was mentioned (VERY naïve guess)
                        if (plugin.printerSettings.bellOnMention)
                        {
                            import kameloso.bash : TerminalToken;
                            sink.put(TerminalToken.bell);
                        }
                    }
                    goto default;

                default:
                    put(sink, `: "`, content, '"');
                    break;
                }
            }
            else
            {
                // PING or ERROR likely
                put(sink, content);
            }
        }

        if (aux.length) put(sink, " <", aux, '>');

        if (num > 0)
        {
            import std.format : formattedWrite;
            sink.formattedWrite(" (#%03d)", num);
        }

        static if (!__traits(hasMember, Sink, "data"))
        {
            sink.put('\n');
        }
        else version(Cygwin)
        {
            stdout.flush();
        }
    }
    else
    {
        version(Colours)
        {
            import kameloso.bash : colour, invert;

            event.mapEffects();

            enum DefaultDark : BashForeground
            {
                timestamp = white,
                type    = lightblue,
                error   = lightred,
                sender  = lightgreen,
                special = lightyellow,
                target  = cyan,
                channel = yellow,
                content = default_,
                aux     = white,
                num     = darkgrey,
                badge   = white,
            }

            enum DefaultBright : BashForeground
            {
                timestamp = black,
                type    = blue,
                error   = red,
                sender  = green,
                special = yellow,
                target  = cyan,
                channel = yellow,
                content = default_,
                aux     = black,
                num     = lightgrey,
                badge   = black,
            }

            immutable bright = settings.brightTerminal;

            BashForeground colourByHash(const string nickname)
            {
                if (plugin.printerSettings.randomNickColours)
                {
                    import std.traits : EnumMembers;

                    static immutable BashForeground[17] fg =
                        [ EnumMembers!BashForeground ];

                    auto colourIndex = hashOf(nickname) % 16;

                    // Map black to white on dark terminals, reverse on bright
                    if (bright)
                    {
                        if (colourIndex == 16) colourIndex = 1;
                    }
                    else
                    {
                        if (colourIndex == 1) colourIndex = 16;
                    }

                    return fg[colourIndex];
                }

                return bright ? DefaultBright.sender : DefaultDark.sender;
            }

            void colourSenderTruecolour(Sink)(auto ref Sink sink)
            {
                if (!sender.isServer && event.colour.length &&
                    plugin.printerSettings.truecolour)
                {
                    import kameloso.bash : truecolour;
                    import kameloso.string : numFromHex;

                    int r, g, b;
                    event.colour.numFromHex(r, g, b);

                    if (plugin.printerSettings.normaliseTruecolour)
                    {
                        sink.truecolour!(Yes.normalise)
                            (r, g, b, settings.brightTerminal);
                    }
                    else
                    {
                        sink.truecolour!(No.normalise)
                            (r, g, b, settings.brightTerminal);
                    }
                }
                else
                {
                    sink.colour(colourByHash(sender.isServer ? address : nickname));
                }
            }

            BashForeground typeColour;

            if (bright)
            {
                typeColour = (type == IRCEvent.Type.QUERY) ?
                    green : DefaultBright.type;
            }
            else
            {
                typeColour = (type == IRCEvent.Type.QUERY) ?
                    lightgreen : DefaultDark.type;
            }

            sink.colour(bright ? DefaultBright.timestamp : DefaultDark.timestamp);
            put(sink, '[', timestamp, "] ");

            string typestring = plugin.printerSettings.typesInCaps ?
                enumToString(type) : enumToString(type).toLower;

            if (typestring.beginsWith("RPL_") || typestring.beginsWith("rpl_"))
            {
                typestring = typestring[4..$];
                sink.colour(typeColour);
            }
            else if (typestring.beginsWith("ERR_") || typestring.beginsWith("err_"))
            {
                typestring = typestring[4..$];
                sink.colour(bright ? DefaultBright.error : DefaultDark.error);
            }
            else
            {
                sink.colour(typeColour);
            }

            put(sink, '[', typestring, "] ");

            bool aliasPrinted;

            colourSenderTruecolour(sink);

            if (sender.isServer)
            {
                sink.put(address);
            }
            else
            {
                if (alias_.length && alias_.asLowerCase.equal(nickname))
                {
                    sink.put(alias_);
                    aliasPrinted = true;
                }
                else
                {
                    sink.put(nickname);
                }

                if (special && nickname.length)
                {
                    sink.colour(bright ? DefaultBright.special : DefaultDark.special);
                    sink.put('*');
                }
            }

            if (badge.length)
            {
                import std.string : toUpper;

                sink.colour(bright ? DefaultBright.badge : DefaultDark.badge);

                immutable badgestring = plugin.printerSettings.badgesInCaps ?
                    badge.toUpper : badge;

                put(sink, " [", badgestring, ']');
            }

            if (!sender.isServer && alias_.length && !aliasPrinted)
            {
                put(sink, " (", alias_, ')');
            }

            if (target.nickname.length)
            {
                sink.colour(colourByHash(target.nickname));
                put(sink, " (", target.nickname, ')');
            }

            if (channel.length)
            {
                sink.colour(bright ? DefaultBright.channel : DefaultDark.channel);
                put(sink, " [", channel, ']');
            }

            if (content.length)
            {
                sink.colour(bright ? DefaultBright.content : DefaultDark.content);

                if (sender.isServer || nickname.length)
                {
                    import std.algorithm.searching : canFind;

                    with (IRCEvent.Type)
                    switch (type)
                    {
                    case CHAN:
                    case QUERY:
                        if ((cast(ubyte[])event.content)
                            .canFind(cast(ubyte[])bot.nickname))
                        {
                            // Nick was mentioned (naïve guess)

                            immutable inverted = plugin.nicknameHasElaborateBoundary ?
                                content.invert!(Yes.elaborateBoundary)(bot.nickname) :
                                content.invert!(No.elaborateBoundary)(bot.nickname);

                            if ((content != inverted) &&
                                (plugin.printerSettings.bellOnMention))
                            {
                                import kameloso.bash : TerminalToken;
                                sink.put(TerminalToken.bell);
                            }

                            put(sink, `: "`, inverted, '"');
                        }
                        else
                        {
                            goto default;
                        }
                        break;

                    default:
                        put(sink, `: "`, content, '"');
                        break;
                    }
                }
                else
                {
                    // PING or ERROR likely
                    put(sink, content);
                }
            }

            if (aux.length)
            {
                sink.colour(bright ? DefaultBright.aux : DefaultDark.aux);
                put(sink, " <", aux, '>');
            }

            if (num > 0)
            {
                import std.format : formattedWrite;

                sink.colour(bright ? DefaultBright.num : DefaultDark.num);
                sink.formattedWrite(" (#%03d)", num);
            }

            sink.colour(default_);  // same for bright and dark

            static if (!__traits(hasMember, Sink, "data"))
            {
                sink.put('\n');
            }
            else version(Cygwin)
            {
                stdout.flush();
            }
        }
        else
        {
            // This will only change this plugin's monochrome setting...
            // We have no way to propagate it
            settings.monochrome = true;
            return plugin.formatMessage(sink, event, settings.monochrome);
        }
    }
}


// mapEffects
/++
 +  Map mIRC effect tokens (colour, bold, italics, underlined) to Bash ones.
 +/
version(Colours)
void mapEffects(ref IRCEvent event)
{
    import kameloso.bash : BashEffect;
    import kameloso.constants : IRCControlCharacter;
    import std.algorithm.searching : canFind;
    import std.string : representation;

    alias I = IRCControlCharacter;
    alias B = BashEffect;

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
 +/
version(Colours)
void mapColours(ref IRCEvent event)
{
    import kameloso.bash : BashBackground, BashForeground, BashReset,
        TerminalToken, colour;
    import std.regex : ctRegex, matchAll, regex, replaceAll;

    enum colourPattern = 3 ~ "([0-9]{1,2})(?:,([0-9]{1,2}))?";
    static engine = ctRegex!colourPattern;

    bool colouredSomething;

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
        import std.array : Appender;
        import std.conv : to;

        Appender!string sink;
        sink.reserve(8);

        if (!hit[1].length) continue;

        immutable fgIndex = hit[1].to!size_t;

        if (fgIndex > 15)
        {
            logger.warning("mIRC foreground colour code out of bounds: ",
                           fgIndex);
            continue;
        }

        sink.put(TerminalToken.bashFormat ~ "[");
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
        colouredSomething = true;
    }

    if (colouredSomething)
    {
        import kameloso.constants : IRCControlCharacter;

        enum endPattern = IRCControlCharacter.colour ~ "([^0-9])?";
        static endEngine = ctRegex!endPattern;

        event.content = event.content.replaceAll(endEngine,
            TerminalToken.bashFormat ~ "[0m$1");
        event.content ~= BashReset.all.colour;
    }
}

///
version(Colours)
unittest
{
    IRCEvent e1;
    e1.content = "This is " ~ 3 ~ "4all red!" ~ 3 ~ " while this is not.";
    e1.mapColours();
    assert((e1.content == "This is \033[91mall red!\033[0m while this is not.\033[0m"),
        e1.content);

    IRCEvent e2;
    e2.content = "This time there's" ~ 3 ~ "6 no ending token, only magenta.";
    e2.mapColours();
    assert((e2.content == "This time there's\033[35m no ending token, only magenta.\033[0m"),
        e2.content);
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
    import kameloso.bash : BashReset, TerminalToken, colour;
    import std.array : Appender;
    import std.conv  : to;
    import std.regex : ctRegex, matchAll, replaceAll;

    enum bashToken = TerminalToken.bashFormat ~ "[" ~
        (cast(ubyte)bashEffectCode).to!string ~ "m";

    enum pattern = "(?:"~mircToken~")([^"~mircToken~"]*)(?:"~mircToken~")";
    static engine = ctRegex!pattern;

    Appender!string sink;
    sink.reserve(cast(size_t)(event.content.length * 1.1));

    auto hits = event.content.matchAll(engine);

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
            sink.put(TerminalToken.bashFormat ~ "[22m");
            break;

        case 3:
        ..
        case 5:
            sink.put(TerminalToken.bashFormat ~ "[2" ~
                bashEffectCode.to!string ~ "m");
            break;

        default:
            logger.warning("Unknown Bash effect code: ", bashEffectCode);
            sink.colour(BashReset.all);
            break;
        }

        hits = hits.post.matchAll(engine);
    }

    // We've gone through them pair-wise, now see if there are any singles left
    static singleTokenEngine = ctRegex!([cast(char)mircToken]);
    sink.put(hits.post.replaceAll(singleTokenEngine, bashToken));

    // End tags and commit
    sink.colour(BashReset.all);
    event.content = sink.data;
}

///
version(Colours)
unittest
{
    import kameloso.bash : BashEffect, TerminalToken;
    import kameloso.constants : IRCControlCharacter;
    import std.conv : to;

    alias I = IRCControlCharacter;
    alias B = BashEffect;

    enum bBold = TerminalToken.bashFormat ~ "[" ~ (cast(ubyte)B.bold).to!string ~ "m";
    enum bReset = TerminalToken.bashFormat ~ "[22m";
    enum bResetAll = TerminalToken.bashFormat ~ "[0m";

    immutable line1 = "ABC"~I.bold~"DEF"~I.bold~"GHI"~I.bold~"JKL"~I.bold~"MNO";
    immutable line2 = "ABC"~bBold~"DEF"~bReset~"GHI"~bBold~"JKL"~bReset~"MNO"~bResetAll;

    IRCEvent event;
    event.content = line1;
    event.mapEffects();
    assert((event.content == line2), line1);
}


mixin BasicEventHandlers;

public:


// Printer
/++
 +  The Printer plugin takes all `IRCEvent`s and prints them to the local
 +  terminal, formatted and optionally in colour.
 +
 +  This used to be part of the core program, but with UDAs it's easy to split
 +  off into its own plugin.
 +/
final class PrinterPlugin : IRCPlugin
{
    /// All Printer plugin options gathered
    @Settings PrinterSettings printerSettings;

    /// Bot's nickname ends with a non-word character
    bool nicknameHasElaborateBoundary;

    mixin IRCPluginImpl;
}

/++
    Implementation of Printer plugin functionality that concerns formatting.
    For internal use.

    The [dialect.defs.IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.printer.base.PrinterPlugin], but these implementation
    functions can be offloaded here to limit module size a bit.
 +/
module kameloso.plugins.printer.formatting;

version(WithPlugins):
version(WithPrinterPlugin):

private:

import kameloso.plugins.printer.base;

import kameloso.irccolours;
import dialect.defs;
import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

version(Colours) import kameloso.terminal : TerminalForeground;

package:

@safe:

version(Colours)
{
    alias TF = TerminalForeground;

    /++
        Default colours for printing events on a dark terminal background.
     +/
    enum EventPrintingDark : TerminalForeground
    {
        type      = TF.lightblue,
        error     = TF.lightred,
        sender    = TF.lightgreen,
        target    = TF.cyan,
        channel   = TF.yellow,
        content   = TF.default_,
        aux       = TF.white,
        count     = TF.green,
        altcount  = TF.lightgreen,
        num       = TF.darkgrey,
        badge     = TF.white,
        emote     = TF.cyan,
        highlight = TF.white,
        query     = TF.lightgreen,
    }

    /++
        Default colours for printing events on a bright terminal background.
     +/
    enum EventPrintingBright : TerminalForeground
    {
        type      = TF.blue,
        error     = TF.red,
        sender    = TF.green,
        target    = TF.cyan,
        channel   = TF.yellow,
        content   = TF.default_,
        aux       = TF.black,
        count     = TF.lightgreen,
        altcount  = TF.green,
        num       = TF.lightgrey,
        badge     = TF.black,
        emote     = TF.lightcyan,
        highlight = TF.black,
        query     = TF.green,
    }
}


// put
/++
    Puts a variadic list of values into an output range sink.

    Params:
        colours = Whether or not to accept terminal colour tokens and use
            them to tint the text.
        sink = Output range to sink items into.
        args = Variadic list of things to put into the output range.
 +/
void put(Flag!"colours" colours = No.colours, Sink, Args...)
    (auto ref Sink sink, Args args)
if (isOutputRange!(Sink, char[]))
{
    import std.traits : Unqual;

    foreach (arg; args)
    {
        alias T = Unqual!(typeof(arg));

        version(Colours)
        {
            import kameloso.terminal : isAColourCode;

            bool coloured;

            static if (colours && isAColourCode!T)
            {
                import kameloso.terminal : colourWith;
                sink.colourWith(arg);
                coloured = true;
            }

            if (coloured) continue;
        }

        static if (__traits(compiles, sink.put(T.init)) && !is(T == bool))
        {
            sink.put(arg);
        }
        else static if (is(T == bool))
        {
            sink.put(arg ? "true" : "false");
        }
        else static if (is(T : long))
        {
            import lu.conv : toAlphaInto;
            arg.toAlphaInto(sink);
        }
        else
        {
            import std.conv : to;
            sink.put(arg.to!string);
        }
    }
}

///
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    .put(sink, "abc", long.min, "def", 456, true);
    assert((sink.data == "abc-9223372036854775808def456true"), sink.data);

    version(Colours)
    {
        import kameloso.terminal : TerminalBackground, TerminalForeground, TerminalReset;

        sink = typeof(sink).init;

        .put!(Yes.colours)(sink, "abc", TerminalForeground.white, "def",
            TerminalBackground.red, "ghi", TerminalReset.all, "123");
        assert((sink.data == "abc\033[97mdef\033[41mghi\033[0m123"), sink.data);
    }
}


// formatMessageMonochrome
/++
    Formats an [dialect.defs.IRCEvent] into an output range sink, in monochrome.

    It formats the timestamp, the type of the event, the sender or sender alias,
    the channel or target, the content body, as well as auxiliary information.

    Params:
        plugin = Current [kameloso.plugins.printer.base.PrinterPlugin].
        sink = Output range to format the [dialect.defs.IRCEvent] into.
        event = The [dialect.defs.IRCEvent] that is to be formatted.
        bellOnMention = Whether or not to emit a terminal bell when the bot's
            nickname is mentioned in chat.
        bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
void formatMessageMonochrome(Sink)(PrinterPlugin plugin, auto ref Sink sink, IRCEvent event,
    const Flag!"bellOnMention" bellOnMention,
    const Flag!"bellOnError" bellOnError)
if (isOutputRange!(Sink, char[]))
{
    import lu.conv : Enum;
    import std.algorithm.comparison : equal;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;
    import std.uni : asLowerCase, asUpperCase;

    immutable typestring = Enum!(IRCEvent.Type).toString(event.type).withoutTypePrefix;

    bool shouldBell;

    static if (!__traits(hasMember, Sink, "data"))
    {
        scope(exit)
        {
            sink.put('\n');
        }
    }

    void putSender()
    {
        if (event.sender.isServer)
        {
            sink.put(event.sender.address);
        }
        else
        {
            bool putDisplayName;

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    event.sender.displayName.length)
                {
                    sink.put(event.sender.displayName);
                    putDisplayName = true;

                    if ((event.sender.displayName != event.sender.nickname) &&
                        !event.sender.displayName.asLowerCase.equal(event.sender.nickname))
                    {
                        .put(sink, " (", event.sender.nickname, ')');
                    }
                }
            }

            if (!putDisplayName && event.sender.nickname.length)
            {
                // Can be no-nick special: [PING] *2716423853
                sink.put(event.sender.nickname);
            }

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    plugin.printerSettings.twitchBadges && event.sender.badges.length)
                {
                    with (IRCEvent.Type)
                    switch (event.type)
                    {
                    case JOIN:
                    case SELFJOIN:
                    case PART:
                    case SELFPART:
                    case QUERY:
                    //case SELFQUERY:  // Doesn't seem to happen
                        break;

                    default:
                        .put(sink, " [", event.sender.badges, ']');
                        break;
                    }
                }
            }
        }
    }

    void putTarget()
    {
        sink.put(" -> ");

        bool putDisplayName;

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                event.target.displayName.length)
            {
                sink.put(event.target.displayName);
                putDisplayName = true;

                if ((event.target.displayName != event.target.nickname) &&
                    !event.target.displayName.asLowerCase.equal(event.target.nickname))
                {
                    .put(sink, " (", event.target.nickname, ')');
                }
            }
        }

        if (!putDisplayName)
        {
            sink.put(event.target.nickname);
        }

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                plugin.printerSettings.twitchBadges && event.target.badges.length)
            {
                .put(sink, " [", event.target.badges, ']');
            }
        }
    }

    void putContent()
    {
        if (event.sender.isServer || event.sender.nickname.length)
        {
            immutable isEmote = (event.type == IRCEvent.Type.EMOTE) ||
                (event.type == IRCEvent.Type.SELFEMOTE);

            if (isEmote)
            {
                sink.put(' ');
            }
            else
            {
                sink.put(`: "`);
            }

            with (IRCEvent.Type)
            switch (event.type)
            {
            case CHAN:
            case EMOTE:
            case TWITCH_SUBGIFT:
                if (plugin.state.client.nickname.length &&
                    event.content.containsNickname(plugin.state.client.nickname))
                {
                    // Nick was mentioned (certain)
                    shouldBell = bellOnMention;
                }
                break;

            default:
                break;
            }

            sink.put(event.content);
            if (!isEmote) sink.put('"');
        }
        else
        {
            // PING or ERROR likely
            sink.put(event.content);  // No need for indenting space
        }
    }

    event.content = stripEffects(event.content);

    sink.put('[');

    (cast(DateTime)SysTime
        .fromUnixTime(event.time))
        .timeOfDay
        .toString(sink);

    sink.put("] [");

    if (plugin.printerSettings.uppercaseTypes)
    {
        sink.put(typestring);
    }
    else
    {
        sink.put(typestring.asLowerCase);
    }

    sink.put("] ");

    if (event.channel.length) .put(sink, '[', event.channel, "] ");

    putSender();

    if (event.target.nickname.length) putTarget();

    if (event.content.length) putContent();

    if (event.aux.length) .put(sink, " (", event.aux, ')');

    if (event.count != long.min) .put(sink, " {", event.count, '}');

    if (event.altcount != long.min) .put(sink, " {", event.altcount, '}');

    if (event.num > 0)
    {
        import lu.conv : toAlphaInto;

        //sink.formattedWrite(" (#%03d)", num);
        sink.put(" (#");
        event.num.toAlphaInto!(3, 3)(sink);
        sink.put(')');
    }

    if (event.errors.length)
    {
        .put(sink, " ! ", event.errors, " !");
    }

    shouldBell = shouldBell || (event.errors.length && bellOnError);

    if (shouldBell) sink.put(plugin.bell);
}

///
@system unittest
{
    import kameloso.plugins.common.core : IRCPluginState;
    import std.array : Appender;

    Appender!(char[]) sink;

    IRCPluginState state;
    state.server.daemon = IRCServer.Daemon.twitch;
    PrinterPlugin plugin = new PrinterPlugin(state);

    IRCEvent event;

    with (event.sender)
    {
        nickname = "nickname";
        address = "127.0.0.1";
        version(TwitchSupport) displayName = "Nickname";
        //account = "n1ckn4m3";
        class_ = IRCUser.Class.whitelist;
    }

    event.type = IRCEvent.Type.JOIN;
    event.channel = "#channel";

    plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
    immutable joinLine = sink.data[11..$].idup;
    version(TwitchSupport) assert((joinLine == "[join] [#channel] Nickname"), joinLine);
    else assert((joinLine == "[join] [#channel] nickname"), joinLine);
    sink = typeof(sink).init;

    event.type = IRCEvent.Type.CHAN;
    event.content = "Harbl snarbl";

    plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
    immutable chanLine = sink.data[11..$].idup;
    version(TwitchSupport) assert((chanLine == `[chan] [#channel] Nickname: "Harbl snarbl"`), chanLine);
    else assert((chanLine == `[chan] [#channel] nickname: "Harbl snarbl"`), chanLine);
    sink = typeof(sink).init;

    version(TwitchSupport)
    {
        event.sender.badges = "broadcaster/0,moderator/1,subscriber/9";
        //colour = "#3c507d";

        plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
        immutable twitchLine = sink.data[11..$].idup;
        assert((twitchLine == `[chan] [#channel] Nickname [broadcaster/0,moderator/1,subscriber/9]: "Harbl snarbl"`),
            twitchLine);
        sink = typeof(sink).init;
        event.sender.badges = string.init;
    }

    event.type = IRCEvent.Type.ACCOUNT;
    event.channel = string.init;
    event.content = string.init;
    event.sender.account = "n1ckn4m3";
    event.aux = "n1ckn4m3";

    plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
    immutable accountLine = sink.data[11..$].idup;
    version(TwitchSupport) assert((accountLine == "[account] Nickname (n1ckn4m3)"), accountLine);
    else assert((accountLine == "[account] nickname (n1ckn4m3)"), accountLine);
    sink = typeof(sink).init;

    event.errors = "DANGER WILL ROBINSON";
    event.content = "Blah balah";
    event.num = 666;
    event.count = -42;
    event.aux = string.init;
    event.type = IRCEvent.Type.ERROR;

    plugin.formatMessageMonochrome(sink, event, No.bellOnMention, No.bellOnError);
    immutable errorLine = sink.data[11..$].idup;
    version(TwitchSupport) assert((errorLine == `[error] Nickname: "Blah balah" {-42} (#666) ` ~
        "! DANGER WILL ROBINSON !"), errorLine);
    else assert((errorLine == `[error] nickname: "Blah balah" {-42} (#666) ` ~
        "! DANGER WILL ROBINSON !"), errorLine);
    //sink = typeof(sink).init;
}


// formatMessageColoured
/++
    Formats an [dialect.defs.IRCEvent] into an output range sink, coloured.

    It formats the timestamp, the type of the event, the sender or the sender's
    display name, the channel or target, the content body, as well as auxiliary
    information and numbers.

    Params:
        plugin = Current [kameloso.plugins.printer.base.PrinterPlugin].
        sink = Output range to format the [dialect.defs.IRCEvent] into.
        event = The [dialect.defs.IRCEvent] that is to be formatted.
        bellOnMention = Whether or not to emit a terminal bell when the bot's
            nickname is mentioned in chat.
        bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
version(Colours)
void formatMessageColoured(Sink)(PrinterPlugin plugin, auto ref Sink sink, IRCEvent event,
    const Flag!"bellOnMention" bellOnMention,
    const Flag!"bellOnError" bellOnError)
if (isOutputRange!(Sink, char[]))
{
    import kameloso.constants : DefaultColours;
    import kameloso.terminal : FG = TerminalForeground, colourWith;
    import lu.conv : Enum;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;

    alias Bright = EventPrintingBright;
    alias Dark = EventPrintingDark;
    alias Timestamp = DefaultColours.TimestampColour;

    immutable rawTypestring = Enum!(IRCEvent.Type).toString(event.type);
    immutable typestring = rawTypestring.withoutTypePrefix;

    bool shouldBell;

    immutable bright = plugin.state.settings.brightTerminal ? Yes.bright : No.bright;

    /++
        Outputs a terminal ANSI colour token based on the hash of the passed
        nickname.

        It gives each user a random yet consistent colour to their name.
     +/
    FG colourByHash(const string nickname)
    {
        import std.traits : EnumMembers;

        alias foregroundMembers = EnumMembers!TerminalForeground;

        static immutable TerminalForeground[foregroundMembers.length+(-3)] fgBright =
        [
            //FG.default_,
            FG.black,
            FG.red,
            FG.green,
            //FG.yellow,  // Blends too much with channel
            FG.blue,
            FG.magenta,
            FG.cyan,
            FG.lightgrey,
            FG.darkgrey,
            FG.lightred,
            FG.lightgreen,
            FG.lightyellow,
            FG.lightblue,
            FG.lightmagenta,
            FG.lightcyan,
            //FG.white,
        ];

        static immutable TerminalForeground[foregroundMembers.length+(-3)] fgDark =
        [
            //FG.default_,
            //FG.black,
            FG.red,
            FG.green,
            //FG.yellow,
            FG.blue,
            FG.magenta,
            FG.cyan,
            FG.lightgrey,
            FG.darkgrey,
            FG.lightred,
            FG.lightgreen,
            FG.lightyellow,
            FG.lightblue,
            FG.lightmagenta,
            FG.lightcyan,
            FG.white,
        ];

        if (plugin.printerSettings.randomNickColours)
        {
            import kameloso.terminal : colourByHash;
            return colourByHash(nickname, bright ? fgBright[] : fgDark[]);
        }
        else
        {
            // Don't differentiate between sender and target? Consistency?
            return FG(bright ? Bright.sender : Dark.sender);
        }
    }

    /++
        Outputs a terminal truecolour token based on the #RRGGBB value stored in
        `user.colour`.

        This is for Twitch servers that assign such values to users' messages.
        By catching it we can honour the setting by tinting users accordingly.
     +/
    void colourUserTruecolour(Sink)(auto ref Sink sink, const IRCUser user)
    if (isOutputRange!(Sink, char[]))
    {
        bool coloured;

        version(TwitchSupport)
        {
            if (!user.isServer && user.colour.length && plugin.printerSettings.truecolour)
            {
                import kameloso.terminal : truecolour;
                import lu.conv : numFromHex;

                int r, g, b;
                user.colour.numFromHex(r, g, b);

                if (plugin.printerSettings.normaliseTruecolour)
                {
                    sink.truecolour!(Yes.normalise)(r, g, b, bright);
                }
                else
                {
                    sink.truecolour!(No.normalise)(r, g, b, bright);
                }
                coloured = true;
            }
        }

        if (!coloured)
        {
            immutable name = user.isServer ?
                user.address :
                ((user.account.length && plugin.printerSettings.colourByAccount) ?
                    user.account :
                    user.nickname);

            sink.colourWith(colourByHash(name));
        }
    }

    static if (!__traits(hasMember, Sink, "data"))
    {
        scope(exit)
        {
            sink.put('\n');
        }
    }

    void putSender()
    {
        colourUserTruecolour(sink, event.sender);

        if (event.sender.isServer)
        {
            sink.put(event.sender.address);
        }
        else
        {
            bool putDisplayName;

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    event.sender.displayName.length)
                {
                    sink.put(event.sender.displayName);
                    putDisplayName = true;

                    import std.algorithm.comparison : equal;
                    import std.uni : asLowerCase;

                    if ((event.sender.displayName != event.sender.nickname) &&
                        !event.sender.displayName.asLowerCase.equal(event.sender.nickname))
                    {
                        .put!(Yes.colours)(sink, FG.default_, " (");
                        colourUserTruecolour(sink, event.sender);
                        .put!(Yes.colours)(sink, event.sender.nickname, FG.default_, ')');
                    }
                }
            }

            if (!putDisplayName && event.sender.nickname.length)
            {
                // Can be no-nick special: [PING] *2716423853
                sink.put(event.sender.nickname);
            }

            version(TwitchSupport)
            {
                if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                    plugin.printerSettings.twitchBadges && event.sender.badges.length)
                {
                    with (IRCEvent.Type)
                    switch (event.type)
                    {
                    case JOIN:
                    case SELFJOIN:
                    case PART:
                    case SELFPART:
                        break;

                    default:
                        .put!(Yes.colours)(sink,
                            TerminalForeground(bright ? Bright.badge : Dark.badge),
                            " [", event.sender.badges, ']');
                        break;
                    }
                }
            }
        }
    }

    void putTarget()
    {
        // No need to check isServer; target is never server
        .put!(Yes.colours)(sink, FG.default_, " -> ");
        colourUserTruecolour(sink, event.target);

        bool putDisplayName;

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                event.target.displayName.length)
            {
                sink.put(event.target.displayName);
                putDisplayName = true;

                import std.algorithm.comparison : equal;
                import std.uni : asLowerCase;

                if ((event.target.displayName != event.target.nickname) &&
                    !event.target.displayName.asLowerCase.equal(event.target.nickname))
                {
                    sink.put(" (");
                    colourUserTruecolour(sink, event.target);
                    .put!(Yes.colours)(sink, event.target.nickname, FG.default_, ')');
                }
            }
        }

        if (!putDisplayName)
        {
            sink.put(event.target.nickname);
        }

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                plugin.printerSettings.twitchBadges && event.target.badges.length)
            {
                .put!(Yes.colours)(sink,
                    TerminalForeground(bright ? Bright.badge : Dark.badge),
                    " [", event.target.badges, ']');

            }
        }
    }

    void putContent()
    {
        immutable FG contentFgBase = bright ? Bright.content : Dark.content;
        immutable FG emoteFgBase = bright ? Bright.emote : Dark.emote;

        immutable fgBase = ((event.type == IRCEvent.Type.EMOTE) ||
            (event.type == IRCEvent.Type.SELFEMOTE)) ? emoteFgBase : contentFgBase;
        immutable isEmote = (fgBase == emoteFgBase);

        sink.colourWith(fgBase);  // Always grey colon and SASL +, prepare for emote

        if (event.sender.isServer || event.sender.nickname.length)
        {
            if (isEmote)
            {
                sink.put(' ');
            }
            else
            {
                sink.put(`: "`);
            }

            if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
            {
                // Twitch chat has no colours or effects, only emotes
                event.content = mapEffects(event.content, fgBase);
            }

            version(TwitchSupport)
            {
                if (plugin.state.server.daemon == IRCServer.Daemon.twitch)
                {
                    highlightEmotes(event,
                        (plugin.printerSettings.colourfulEmotes ? Yes.colourful : No.colourful),
                        (plugin.state.settings.brightTerminal ? Yes.brightTerminal : No.brightTerminal));
                }
            }

            with (IRCEvent.Type)
            switch (event.type)
            {
            case CHAN:
            case EMOTE:
            case TWITCH_SUBGIFT:
            //case SELFCHAN:
                import kameloso.terminal : invert;

                /// Nick was mentioned (certain)
                bool match;
                string inverted = event.content;

                if (event.content.containsNickname(plugin.state.client.nickname))
                {
                    inverted = event.content.invert(plugin.state.client.nickname);
                    match = true;
                }

                version(TwitchSupport)
                {
                    // On Twitch, also highlight the display name alias
                    if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                        plugin.state.client.displayName.length &&  // Should always be true but check
                        (plugin.state.client.nickname != plugin.state.client.displayName) &&
                        event.content.containsNickname(plugin.state.client.displayName))
                    {
                        inverted = inverted.invert(plugin.state.client.displayName);
                        match = true;
                    }
                }

                if (!match) goto default;

                sink.put(inverted);
                shouldBell = bellOnMention;
                break;

            default:
                // Normal non-highlighting channel message
                sink.put(event.content);
                break;
            }

            import kameloso.terminal : TerminalBackground;

            // Reset the background to ward off bad backgrounds bleeding out
            sink.colourWith(fgBase, TerminalBackground.default_);
            if (!isEmote) sink.put('"');
        }
        else
        {
            // PING or ERROR likely
            sink.put(event.content);  // No need for indenting space
        }
    }

    .put!(Yes.colours)(sink, TerminalForeground(bright ? Timestamp.bright : Timestamp.dark), '[');

    (cast(DateTime)SysTime
        .fromUnixTime(event.time))
        .timeOfDay
        .toString(sink);

    sink.put(']');

    import lu.string : beginsWith;

    if (rawTypestring.beginsWith("ERR_") || (event.type == IRCEvent.Type.ERROR) ||
        (event.type == IRCEvent.Type.TWITCH_ERROR))
    {
        sink.colourWith(TerminalForeground(bright ? Bright.error : Dark.error));
    }
    else
    {
        if (bright)
        {
            sink.colourWith((event.type == IRCEvent.Type.QUERY) ? Bright.query : Bright.type);
        }
        else
        {
            sink.colourWith((event.type == IRCEvent.Type.QUERY) ? Dark.query : Dark.type);
        }
    }

    import std.uni : asLowerCase;

    sink.put(" [");

    if (plugin.printerSettings.uppercaseTypes)
    {
        sink.put(typestring);
    }
    else
    {
        sink.put(typestring.asLowerCase);
    }

    sink.put("] ");

    if (event.channel.length)
    {
        .put!(Yes.colours)(sink,
            TerminalForeground(bright ? Bright.channel : Dark.channel),
            '[', event.channel, "] ");
    }

    putSender();

    if (event.target.nickname.length) putTarget();

    if (event.content.length) putContent();

    if (event.aux.length)
    {
        .put!(Yes.colours)(sink,
            TerminalForeground(bright ? Bright.aux : Dark.aux),
            " (", event.aux, ')');
    }

    if (event.count != long.min)
    {
        sink.colourWith(TerminalForeground(bright ? Bright.count : Dark.count));
        .put(sink, " {", event.count, '}');
    }

    if (event.altcount != long.min)
    {
        sink.colourWith(TerminalForeground(bright ? Bright.altcount : Dark.altcount));
        .put(sink, " {", event.altcount, '}');
    }

    if (event.num > 0)
    {
        import lu.conv : toAlphaInto;

        sink.colourWith(TerminalForeground(bright ? Bright.num : Dark.num));

        //sink.formattedWrite(" (#%03d)", event.num);
        sink.put(" (#");
        event.num.toAlphaInto!(3, 3)(sink);
        sink.put(')');
    }

    if (event.errors.length)
    {
        .put!(Yes.colours)(sink,
            TerminalForeground(bright ? Bright.error : Dark.error),
            " ! ", event.errors, " !");
    }

    sink.colourWith(FG.default_);  // same for bright and dark

    shouldBell = shouldBell || (event.errors.length && bellOnError);

    if (shouldBell) sink.put(plugin.bell);
}


// withoutTypePrefix
/++
    Slices away any type prefixes from the string of a
    [dialect.defs.IRCEvent.Type].

    Only for shared use in [formatMessageMonochrome] and
    [formatMessageColoured].

    Example:
    ---
    immutable typestring1 = "PRIVMSG".withoutTypePrefix;
    assert((typestring1 == "PRIVMSG"), typestring1);  // passed through

    immutable typestring2 = "ERR_NOSUCHNICK".withoutTypePrefix;
    assert((typestring2 == "NOSUCHNICK"), typestring2);

    immutable typestring3 = "RPL_LIST".withoutTypePrefix;
    assert((typestring3 == "LIST"), typestring3);
    ---

    Params:
        typestring = The string form of a [dialect.defs.IRCEvent.Type].

    Returns:
        A slice of the passed `typestring`, excluding any prefixes if present.
 +/
string withoutTypePrefix(const string typestring) @safe pure nothrow @nogc @property
{
    import lu.string : beginsWith;

    if (typestring.beginsWith("RPL_") || typestring.beginsWith("ERR_"))
    {
        return typestring[4..$];
    }
    else
    {
        version(TwitchSupport)
        {
            if (typestring.beginsWith("TWITCH_"))
            {
                return typestring[7..$];
            }
        }
    }

    return typestring;  // as is
}

///
unittest
{
    {
        immutable typestring = "RPL_ENDOFMOTD";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "ENDOFMOTD"), without);
    }
    {
        immutable typestring = "ERR_CHANOPRIVSNEEDED";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "CHANOPRIVSNEEDED"), without);
    }
    version(TwitchSupport)
    {{
        immutable typestring = "TWITCH_USERSTATE";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "USERSTATE"), without);
    }}
    {
        immutable typestring = "PRIVMSG";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "PRIVMSG"), without);
    }
}


// highlightEmotes
/++
    Tints emote strings and highlights Twitch emotes in a ref
    [dialect.defs.IRCEvent]'s `content` member.

    Wraps [highlightEmotesImpl].

    Params:
        event = [dialect.defs.IRCEvent] whose content text to highlight.
        colourful = Whether or not emotes should be highlit in colours.
        brightTerminal = Whether or not the terminal has a bright background
            and colours should be adapted to suit.
 +/
version(Colours)
version(TwitchSupport)
void highlightEmotes(ref IRCEvent event,
    const Flag!"colourful" colourful,
    const Flag!"brightTerminal" brightTerminal)
{
    import kameloso.constants : DefaultColours;
    import kameloso.terminal : colourWith;
    import lu.string : contains;
    import std.array : Appender;

    alias Bright = EventPrintingBright;
    alias Dark = EventPrintingDark;

    if (!event.emotes.length) return;

    static Appender!(char[]) sink;
    scope(exit) sink.clear();
    sink.reserve(event.content.length + 60);  // mostly +10

    immutable TerminalForeground highlight = brightTerminal ?
        Bright.highlight : Dark.highlight;

    immutable isEmoteOnly = !colourful && event.tags.contains("emote-only=1");

    with (IRCEvent.Type)
    switch (event.type)
    {
    case EMOTE:
    case SELFEMOTE:
        if (isEmoteOnly)
        {
            // Just highlight the whole line, don't worry about resetting to fgBase
            sink.colourWith(highlight);
            sink.put(event.content);
            break;
        }

        // Emote but mixed text and emotes OR we're doing colourful emotes
        immutable TerminalForeground emoteFgBase = brightTerminal ?
            Bright.emote : Dark.emote;
        event.content.highlightEmotesImpl(sink, event.emotes, highlight,
            emoteFgBase, colourful, brightTerminal);
        break;

    default:
        if (isEmoteOnly)
        {
            // / Emote only channel message, treat the same as an emote-only emote?
            goto case EMOTE;
        }

        // Normal content, normal text, normal emotes
        immutable TerminalForeground contentFgBase = brightTerminal ?
            Bright.content : Dark.content;
        event.content.highlightEmotesImpl(sink, event.emotes, highlight,
            contentFgBase, colourful, brightTerminal);
        break;
    }

    event.content = sink.data.idup;
}


// highlightEmotesImpl
/++
    Highlights Twitch emotes in the chat by tinting them a different colour,
    saving the results into a passed output range sink.

    Params:
        line = Content line whose containing emotes should be highlit.
        sink = Output range to put the results into.
        emotes = The list of emotes and their positions as divined from the
            IRCv3 tags of an event.
        pre = Terminal foreground tint to colour the emotes with.
        post = Terminal foreground tint to reset to after colouring an emote.
        colourful = Whether or not emotes should be highlit in colours.
        brightTerminal = Whether or not the terminal has a bright background
            and colours should be adapted to suit.
 +/
version(Colours)
version(TwitchSupport)
void highlightEmotesImpl(Sink)(const string line, auto ref Sink sink,
    const string emotes, const TerminalForeground pre, const TerminalForeground post,
    const Flag!"colourful" colourful,
    const Flag!"brightTerminal" brightTerminal)
if (isOutputRange!(Sink, char[]))
{
    import std.algorithm.iteration : splitter;
    import std.conv : to;

    static struct Highlight
    {
        string id;
        size_t start;
        size_t end;
    }

    // max encountered emotes so far: 46
    // Severely pathological let's-crash-the-bot case: max possible ~161 emotes
    // That is a standard PRIVMSG line with ":) " repeated until 512 chars.
    // Highlight[162].sizeof == 2592, manageable stack size.
    enum maxHighlights = 162;

    Highlight[maxHighlights] highlights;

    size_t numHighlights;
    size_t pos;

    foreach (emote; emotes.splitter('/'))
    {
        import lu.string : nom;

        immutable emoteID = emote.nom(':');

        foreach (immutable location; emote.splitter(','))
        {
            import std.string : indexOf;

            if (numHighlights == maxHighlights) break;  // too many, don't go out of bounds.

            immutable dashPos = location.indexOf('-');
            immutable start = location[0..dashPos].to!size_t;
            immutable end = location[dashPos+1..$].to!size_t + 1;  // inclusive

            highlights[numHighlights++] = Highlight(emoteID, start, end);
        }
    }

    import std.algorithm.sorting : sort;
    highlights[0..numHighlights].sort!((a, b) => a.start < b.start)();

    // We need a dstring since we're slicing something that isn't necessarily ASCII
    // Without this highlights become offset a few characters depending on the text
    immutable dline = line.to!dstring;

    foreach (immutable i; 0..numHighlights)
    {
        import kameloso.terminal : colourByHash, colourWith;

        immutable id = highlights[i].id;
        immutable start = highlights[i].start;
        immutable end = highlights[i].end;

        sink.put(dline[pos..start]);
        sink.colourWith(colourful ? colourByHash(id, brightTerminal) : pre);
        sink.put(dline[start..end]);
        sink.colourWith(post);

        pos = end;
    }

    // Add the remaining tail from after the last emote
    sink.put(dline[pos..$]);
}

///
version(Colours)
version(TwitchSupport)
unittest
{
    import std.array : Appender;

    Appender!(char[]) sink;

    {
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "Moody the god \033[97mpownyFine\033[39m \033[97mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "NOOOOOO \033[97mcamillsCry\033[39m " ~
            "\033[97mcamillsCry\033[39m \033[97mcamillsCry\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "822112:0-6,8-14,16-22";
        immutable line = "FortOne FortOne FortOne";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "\033[97mFortOne\033[39m \033[97mFortOne\033[39m " ~
            "\033[97mFortOne\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "141844:17-24,26-33,35-42/141073:9-15";
        immutable line = "@mugs123 cohhWow cohhBoop cohhBoop cohhBoop";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "@mugs123 \033[97mcohhWow\033[39m \033[97mcohhBoop\033[39m " ~
            "\033[97mcohhBoop\033[39m \033[97mcohhBoop\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "12345:81-91,93-103";
        immutable line = "Link Amazon Prime to your Twitch account and get a " ~
            "FREE SUBSCRIPTION every month courageHYPE courageHYPE " ~
            "twitch.amazon.com/prime | Click subscribe now to check if a " ~
            "free prime sub is available to use!";
        immutable highlitLine = "Link Amazon Prime to your Twitch account and get a " ~
            "FREE SUBSCRIPTION every month \033[97mcourageHYPE\033[39m \033[97mcourageHYPE\033[39m " ~
            "twitch.amazon.com/prime | Click subscribe now to check if a " ~
            "free prime sub is available to use!";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == highlitLine), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:32-36";
        immutable line = "@kiwiskool but you’re a sub too Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "@kiwiskool but you’re a sub too \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, No.brightTerminal);
        assert((sink.data == "高所恐怖症 \033[97mLUL\033[39m なにぬねの " ~
            "\033[97mLUL\033[39m \033[97m:)\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, No.brightTerminal);
        assert((sink.data == "高所恐怖症 \033[34mLUL\033[39m なにぬねの " ~
            "\033[34mLUL\033[39m \033[91m:)\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, No.brightTerminal);
        assert((sink.data == "Moody the god \033[37mpownyFine\033[39m \033[96mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, No.brightTerminal);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[93mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        line.highlightEmotesImpl(sink, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, No.brightTerminal);
        assert((sink.data == "NOOOOOO \033[95mcamillsCry\033[39m " ~
            "\033[95mcamillsCry\033[39m \033[95mcamillsCry\033[39m"), sink.data);
    }
}


// containsNickname
/++
    Searches a string for a substring that isn't surrounded by characters that
    can be part of a nickname. This can detect a nickname in a string without
    getting false positives from similar nicknames.

    Tries to detect nicknames enclosed in terminal formatting. As such, call this
    *after* having translated IRC- to terminal such with [kameloso.irccolours.mapEffects].

    Uses [std.string.indexOf] internally with hopes of being more resilient to
    weird UTF-8.

    Params:
        haystack = A string to search for the substring nickname.
        needle = The nickname substring to find in `haystack`.

    Returns:
        True if `haystack` contains `needle` in such a way that it is guaranteed
        to not be a different nickname.
 +/
bool containsNickname(const string haystack, const string needle) pure nothrow @nogc
in (needle.length, "Tried to determine whether an empty nickname was in a string")
{
    import kameloso.terminal : TerminalToken;
    import dialect.common : isValidNicknameCharacter;
    import std.string : indexOf;

    if ((haystack.length == needle.length) && (haystack == needle)) return true;

    immutable pos = haystack.indexOf(needle);
    if (pos == -1) return false;

    if (pos > 0)
    {
        bool match;

        version(Colours)
        {
            if ((pos >= 4) && (haystack[pos-1] == 'm'))
            {
                import std.algorithm.comparison : min;
                import std.ascii : isDigit;

                bool previousWasNumber;
                bool previousWasBracket;

                foreach_reverse (immutable i, immutable c; haystack[pos-min(8, pos)..pos-1])
                {
                    if (c.isDigit)
                    {
                        if (previousWasBracket) return false;
                        previousWasNumber = true;
                    }
                    else if (c == ';')
                    {
                        if (!previousWasNumber) return false;
                        previousWasNumber = false;
                    }
                    else if (c == '[')
                    {
                        if (!previousWasNumber) return false;
                        previousWasNumber = false;
                        previousWasBracket = true;
                    }
                    else if (c == TerminalToken.format)
                    {
                        if (!previousWasBracket) return false;

                        // Seems valid, drop down
                        match = true;
                        break;
                    }
                    else
                    {
                        // Invalid character
                        return false;
                    }
                }
            }
        }

        if (match)
        {
            // The above found a formatted nickname
        }
        else if (haystack[pos-1] == '@')
        {
            // "@kameloso"
        }
        else if (haystack[pos-1].isValidNicknameCharacter ||
            (haystack[pos-1] == '.') ||
            (haystack[pos-1] == '/'))
        {
            // URL or run-on word
            return false;
        }
    }

    immutable end = pos + needle.length;

    if (end > haystack.length)
    {
        return false;
    }
    else if (end == haystack.length)
    {
        return true;
    }

    if (haystack[end] == TerminalToken.format)
    {
        // Run-on formatted word
        return true;
    }
    else
    {
        return !haystack[end].isValidNicknameCharacter;
    }
}

///
unittest
{
    assert("kameloso".containsNickname("kameloso"));
    assert(" kameloso ".containsNickname("kameloso"));
    assert(!"kam".containsNickname("kameloso"));
    assert(!"kameloso^".containsNickname("kameloso"));
    assert(!string.init.containsNickname("kameloso"));
    //assert(!"kameloso".containsNickname(""));  // For now let this be false.
    assert("@kameloso".containsNickname("kameloso"));
    assert(!"www.kameloso.com".containsNickname("kameloso"));
    assert("kameloso.".containsNickname("kameloso"));
    assert("kameloso/".containsNickname("kameloso"));
    assert(!"/kameloso/".containsNickname("kameloso"));
    assert(!"kamelosoooo".containsNickname("kameloso"));
    assert(!"".containsNickname("kameloso"));

    version(Colours)
    {
        assert("\033[1mkameloso".containsNickname("kameloso"));
        assert("\033[2;3mkameloso".containsNickname("kameloso"));
        assert("\033[12;34mkameloso".containsNickname("kameloso"));
        assert(!"\033[0m0mkameloso".containsNickname("kameloso"));
        assert(!"\033[kameloso".containsNickname("kameloso"));
        assert(!"\033[mkameloso".containsNickname("kameloso"));
        assert(!"\033[0kameloso".containsNickname("kameloso"));
        assert(!"\033[0mmkameloso".containsNickname("kameloso"));
        assert(!"\033[0;mkameloso".containsNickname("kameloso"));
        assert("\033[12mkameloso\033[1mjoe".containsNickname("kameloso"));
        assert(!"0mkameloso".containsNickname("kameloso"));
    }
}

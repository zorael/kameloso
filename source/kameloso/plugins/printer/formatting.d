/++
    Implementation of Printer plugin functionality that concerns formatting.
    For internal use.

    The [dialect.defs.IRCEvent|IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.printer.PrinterPlugin|PrinterPlugin],
    but these implementation functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.printer],
        [kameloso.plugins.printer.logging]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.printer.formatting;

version(WithPrinterPlugin):

private:

import kameloso.plugins.printer;
import kameloso.pods : CoreSettings;
import dialect.defs;
import std.typecons : Flag, No, Yes;

version(Colours) import kameloso.terminal.colours.defs : TerminalForeground;

package:

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
        aux       = TF.darkgrey,
        count     = TF.green,
        num       = TF.darkgrey,
        badge     = TF.darkgrey,
        emote     = TF.cyan,
        highlight = TF.white,
        query     = TF.lightgreen,
        account   = TF.darkgrey,
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
        aux       = TF.default_,
        count     = TF.lightgreen,
        num       = TF.default_,
        badge     = TF.default_,
        emote     = TF.lightcyan,
        highlight = TF.black,
        query     = TF.green,
        account   = TF.default_,
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
{
    import std.range.primitives : isOutputRange;

    static if (!isOutputRange!(Sink, char[]))
    {
        import std.format : format;

        enum pattern = "`%s` must be passed an output range of `char[]`";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    foreach (arg; args)
    {
        alias T = typeof(arg);

        static if (__traits(compiles, sink.put(T.init)) && !is(T : bool))
        {
            sink.put(arg);
        }
        else static if (is(T == enum))
        {
            import lu.conv : toString;

            static if (__traits(compiles, arg.toString))
            {
                // Preferable
                sink.put(arg.toString);
            }
            else
            {
                import std.conv : to;
                // Fallback
                sink.put(arg.to!string);
            }
        }
        else static if (is(T : bool))
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
    assert((sink[] == "abc-9223372036854775808def456true"), sink[]);
    sink.clear();

    enum E { has = 1, duplicate = 1, values = 1 }
    .put(sink, E.has, E.duplicate, E.values);
    assert((sink[] == "hashashas"), sink[]);  // Not ideal but at least it compiles
    sink.clear();

    .put(sink, 3.14);
    assert((sink[] == "3.14"), sink[]);
}


// formatMessageMonochrome
/++
    Formats an [dialect.defs.IRCEvent|IRCEvent] into an output range sink, in monochrome.

    It formats the timestamp, the type of the event, the sender or sender alias,
    the channel or target, the content body, as well as auxiliary information.

    Params:
        plugin = Current [kameloso.plugins.printer.PrinterPlugin|PrinterPlugin].
        sink = Output range to format the [dialect.defs.IRCEvent|IRCEvent] into.
        event = The [dialect.defs.IRCEvent|IRCEvent] that is to be formatted.
        bellOnMention = Whether or not to emit a terminal bell when the bot's
            nickname is mentioned in chat.
        bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
void formatMessageMonochrome(Sink)
    (PrinterPlugin plugin,
    auto ref Sink sink,
    /*const*/ IRCEvent event,
    const bool bellOnMention,
    const bool bellOnError)
{
    import kameloso.irccolours : stripEffects;
    import std.range.primitives : isOutputRange;
    import std.uni : asLowerCase;

    static if (!isOutputRange!(Sink, char[]))
    {
        import std.format : format;

        enum pattern = "`%s` must be passed an output range of `char[]`";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    /++
        Writes the timestamp and type of the event to the output range sink.
     +/
    void putTimeAndType()
    {
        import lu.conv : toString;
        import std.datetime : DateTime;
        import std.datetime.systime : SysTime;

        sink.put('[');

        (cast(DateTime) SysTime
            .fromUnixTime(event.time))
            .timeOfDay
            .toString(sink);

        sink.put("] [");

        immutable typestring = event.type.toString.withoutTypePrefix;

        if (plugin.settings.uppercaseTypes)
        {
            sink.put(typestring);
        }
        else
        {
            sink.put(typestring.asLowerCase);
        }

        sink.put("] ");
    }

    /++
        Writes the channel name and any potential subchannel name to the output
        range sink.

        If the channel has an ID and the setting is enabled, it is also printed.
     +/
    void putChannels()
    {
        if (event.channel.name.length)
        {
            .put(sink, '[', event.channel.name);

            version(TwitchSupport)
            {
                if (plugin.settings.channelIDs && event.channel.id)
                {
                    .put(sink, ':', event.channel.id);
                }
            }

            .put(sink, "] ");

            if (event.subchannel.name.length && (event.subchannel.name != event.channel.name))
            {
                .put(sink, "< [", event.subchannel.name);

                version(TwitchSupport)
                {
                    if (plugin.settings.channelIDs && event.subchannel.id)
                    {
                        .put(sink, ':', event.subchannel.id);
                    }
                }

                .put(sink, "] ");
            }
        }
    }

    /++
        Writes the sender's nickname, display name, account name, and badges
        to the output range sink.
     +/
    void putSender()
    {
        if (event.sender.isServer)
        {
            sink.put(event.sender.address);
            return;
        }

        bool putDisplayName;

        version(TwitchSupport)
        {
            if (event.sender.displayName.length)
            {
                import std.algorithm.comparison : equal;

                sink.put(event.sender.displayName);
                putDisplayName = true;

                if (plugin.settings.classNames)
                {
                    .put(sink, '/', event.sender.class_);
                }

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

            if (plugin.settings.classNames)
            {
                .put(sink, '/', event.sender.class_);
            }
        }

        if (plugin.settings.accountNames)
        {
            // No need to check for nickname.length, I think
            if ((plugin.state.server.daemon != IRCServer.Daemon.twitch) &&
                event.sender.account.length)
            {
                .put(sink, " (", event.sender.account, ')');
            }
        }

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                plugin.settings.twitchBadges &&
                event.sender.badges.length &&
                (event.sender.badges != "*"))
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

    /++
        Writes the target's nickname, display name, account name, and badges
        to the output range sink.
     +/
    void putTarget()
    {
        if (!event.target.nickname.length) return;

        bool putArrow;
        bool putDisplayName;

        version(TwitchSupport)
        {
            with (IRCEvent.Type)
            switch (event.type)
            {
            case TWITCH_GIFTCHAIN:
            case TWITCH_PAYFORWARD:
                // Add more as they become apparent
                sink.put(" <- ");
                break;

            default:
                sink.put(" -> ");
                break;
            }

            putArrow = true;

            if (event.target.displayName.length)
            {
                import std.algorithm.comparison : equal;

                sink.put(event.target.displayName);
                putDisplayName = true;

                if (plugin.settings.classNames)
                {
                    .put(sink, '/', event.target.class_);
                }

                if ((event.target.displayName != event.target.nickname) &&
                    !event.target.displayName.asLowerCase.equal(event.target.nickname))
                {
                    .put(sink, " (", event.target.nickname, ')');
                }
            }
        }

        if (!putArrow)
        {
            sink.put(" -> ");
        }

        if (!putDisplayName)
        {
            sink.put(event.target.nickname);

            if (plugin.settings.classNames)
            {
                .put(sink, '/', event.target.class_);
            }
        }

        if (plugin.settings.accountNames)
        {
            // No need to check for nickname.length, I think
            if ((plugin.state.server.daemon != IRCServer.Daemon.twitch) &&
                event.target.account.length)
            {
                .put(sink, " (", event.target.account, ')');
            }
        }

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                plugin.settings.twitchBadges &&
                event.target.badges.length &&
                (event.target.badges != "*"))
            {
                .put(sink, " [", event.target.badges, ']');
            }
        }
    }

    /++
        Writes the content of the event to the output range sink.
        If `isAltcontent` is `true`, the content is written in a different style,
        as befits the secondary message-ness of [IRCEvent.altcontent].
     +/
    void putContent(
        const string line,
        ref bool shouldBell,
        const bool isAltcontent = false)
    {
        if (!line.length) return;

        if (!event.sender.isServer && !event.sender.nickname.length)
        {
            // PING or ERROR likely
            sink.put(line);  // No need for delimiter space
            return;
        }

        immutable isEmote =
            !isAltcontent &&  // we can't really tell but treat altcontent as always non-emote
            ((event.type == IRCEvent.Type.EMOTE) ||
            (event.type == IRCEvent.Type.SELFEMOTE));

        bool openQuote;

        if (isAltcontent)
        {
            if (event.target.nickname.length)
            {
                sink.put(`: "`);
                openQuote = true;
            }
            else if (event.content.length)
            {
                sink.put(" | ");
            }
            else
            {
                sink.put(' ');
            }
        }
        else
        {
            if (isEmote)
            {
                sink.put(' ');
            }
            else
            {
                sink.put(`: "`);
                openQuote = true;
            }
        }

        with (IRCEvent.Type)
        switch (event.type)
        {
        case CHAN:
        case EMOTE:
        case TWITCH_SUBGIFT:
        case TWITCH_SUB:
        case TWITCH_ANNOUNCEMENT:
        case TWITCH_CHEER:
        case CLEARMSG:
        //case SELFCHAN:
            if (line.containsNickname(plugin.state.client.nickname))
            {
                // Nick was mentioned (certain)
                shouldBell = bellOnMention;
            }
            break;

        default:
            break;
        }

        sink.put(line);
        if (openQuote) sink.put('"');
    }

    /++
        Writes the auxiliary information of the event to the output range sink.
     +/
    void putAux()
    {
        import std.algorithm.iteration : filter;
        import std.format : formattedWrite;

        auto auxRange = event.aux[].filter!(s => s.length);
        if (!auxRange.empty)
        {
            enum pattern = " (%-(%s%|) (%))";
            sink.formattedWrite(pattern, auxRange);
        }
    }

    /++
        Writes the count information of the event to the output range sink.
     +/
    void putCount()
    {
        import std.algorithm.iteration : filter;
        import std.format : formattedWrite;

        auto countRange = event.count[].filter!(n => !n.isNull);
        if (!countRange.empty)
        {
            enum pattern = " {%-(%s%|} {%)}";
            sink.formattedWrite(pattern, countRange);
        }
    }

    /++
        Writes the numerical ID of the event to the output range sink.
     +/
    void putNum()
    {
        if (event.num > 0)
        {
            import lu.conv : toAlphaInto;

            sink.put(" [#");
            event.num.toAlphaInto!(3, 3)(sink);
            sink.put(']');
        }
    }

    /++
        Writes any errors that occurred during parsing or postprocessing of the
        event to the output range sink.
     +/
    void putErrors()
    {
        if (event.errors.length)
        {
            .put(sink, " ! ", event.errors, " !");
        }
    }

    ////////////////////////////////////////////////////////////////////////////

    static if (!__traits(hasMember, Sink, "data"))
    {
        // May be a lockingTextWriter and the content won't be writeln'd
        scope(exit) sink.put('\n');
    }

    bool shouldBell;

    putTimeAndType();

    putChannels();

    putSender();

    putContent(
        line: stripEffects(event.content),
        shouldBell: shouldBell);

    putTarget();

    if (event.altcontent.length)
    {
        putContent(
            line: stripEffects(event.altcontent),
            shouldBell: shouldBell,
            isAltcontent: true);
        event.aux[$-2] = string.init;  // Remove any custom emote definitions
    }

    putAux();

    putCount();

    putNum();

    putErrors();

    shouldBell |=
        ((event.type == IRCEvent.Type.QUERY) && bellOnMention) ||
        (event.errors.length && bellOnError);

    if (shouldBell) sink.put(plugin.transient.bell);
}

///
@system unittest
{
    import kameloso.plugins : IRCPluginState;
    import lu.assert_ : assertMultilineEquals;
    import std.array : Appender;

    Appender!(char[]) sink;

    IRCPluginState state;
    state.server.daemon = IRCServer.Daemon.twitch;
    state.client.nickname = "nickname";
    PrinterPlugin plugin = new PrinterPlugin(state);

    IRCEvent event;

    with (event.sender)
    {
        nickname = "nickname";
        address = "127.0.0.1";
        version(TwitchSupport) displayName = "Nickname";
        account = "n1ckn4m3";
        class_ = IRCUser.Class.whitelist;
    }

    event.type = IRCEvent.Type.JOIN;
    event.channel.name = "#channel";

    {
        formatMessageMonochrome(plugin, sink, event, bellOnMention: false, bellOnError: false);
        immutable joinLine = sink[][11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        //nickstring ~= "/whitelist";
        immutable expected = "[join] [#channel] " ~ nickstring;
        assertMultilineEquals(actual: joinLine, expected: expected);
        sink.clear();
    }

    event.type = IRCEvent.Type.CHAN;
    event.content = "Harbl snarbl";

    {
        formatMessageMonochrome(plugin, sink, event, bellOnMention: false, bellOnError: false);
        immutable chanLine = sink[][11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        //nickstring ~= "/whitelist";
        immutable expected = "[chan] [#channel] " ~ nickstring ~ `: "Harbl snarbl"`;
        assertMultilineEquals(actual: chanLine, expected: expected);
        sink.clear();
    }

    plugin.settings.classNames = true;
    event.sender.badges = "broadcaster/0,moderator/1,subscriber/9";
    event.sender.class_ = IRCUser.Class.staff;
    //colour = "#3c507d";

    version(TwitchSupport)
    {{
        formatMessageMonochrome(plugin, sink, event, bellOnMention: false, bellOnError: false);
        immutable twitchLine = sink[][11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        nickstring ~= "/staff";
        immutable expected = "[chan] [#channel] " ~ nickstring ~
            ` [broadcaster/0,moderator/1,subscriber/9]: "Harbl snarbl"`;
        assertMultilineEquals(actual: twitchLine, expected: expected);
        sink.clear();
        event.sender.badges = string.init;
    }}

    plugin.settings.accountNames = true;
    plugin.state.server.daemon = IRCServer.Daemon.inspircd;
    event.sender.class_ = IRCUser.Class.anyone;
    event.type = IRCEvent.Type.ACCOUNT;
    event.channel.name = string.init;
    event.content = string.init;
    //event.sender.account = "n1ckn4m3";
    event.aux[0] = "n1ckn4m3";

    {
        formatMessageMonochrome(plugin, sink, event, bellOnMention: false, bellOnError: false);
        immutable accountLine = sink[][11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        nickstring ~= "/anyone";
        nickstring ~= " (n1ckn4m3)";
        immutable expected = "[account] " ~ nickstring ~ " (n1ckn4m3)";
        assertMultilineEquals(actual: accountLine, expected: expected);
        sink.clear();
    }

    event.errors = "DANGER WILL ROBINSON";
    event.content = "Blah balah";
    event.num = 666;
    event.count[0] = -42;
    event.count[1] = 123;
    event.count[5] = 420;
    event.aux[0] = string.init;
    event.aux[1] = "aux1";
    event.aux[4] = "aux5";
    event.type = IRCEvent.Type.ERROR;

    {
        formatMessageMonochrome(plugin, sink, event, bellOnMention: false, bellOnError: false);
        immutable errorLine = sink[][11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        nickstring ~= "/anyone";
        nickstring ~= " (n1ckn4m3)";
        immutable expected = "[error] " ~ nickstring ~ `: "Blah balah" (aux1) (aux5) ` ~
            "{-42} {123} {420} [#666] ! DANGER WILL ROBINSON !";
        //assert((errorLine == expected), errorLine);
        assertMultilineEquals(actual: errorLine, expected: expected);
        sink.clear();
    }

    plugin.settings.classNames = false;
    event.type = IRCEvent.Type.CHAN;
    event.channel.name = "#nickname";
    event.num = 0;
    event.count = typeof(IRCEvent.count).init;
    event.aux = typeof(IRCEvent.aux).init;
    event.errors = string.init;

    {
        formatMessageMonochrome(plugin, sink, event, bellOnMention: false, bellOnError: false);
        immutable line = sink[][11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        //nickstring ~= "/anyone";
        nickstring ~= " (n1ckn4m3)";
        immutable expected = "[chan] [#nickname] " ~ nickstring ~ `: "Blah balah"`;
        assertMultilineEquals(actual: line, expected: expected);
        sink.clear();
    }

    plugin.settings.channelIDs = true;
    event.channel.id = 123;
    event.subchannel.name = "#sub";
    event.subchannel.id = 456;
    event.altcontent = "alt alt alt alt";

    {
        formatMessageMonochrome(plugin, sink, event, bellOnMention: false, bellOnError: false);
        immutable line = sink[][11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        //nickstring ~= "/anyone";
        nickstring ~= " (n1ckn4m3)";
        immutable expected = "[chan] [#nickname:123] < [#sub:456] " ~ nickstring ~ `: "Blah balah" | alt alt alt alt`;
        assertMultilineEquals(actual: line, expected: expected);
        sink.clear();
    }

    event.content = string.init;

    {
        formatMessageMonochrome(plugin, sink, event, bellOnMention: false, bellOnError: false);
        immutable line = sink[][11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        //nickstring ~= "/anyone";
        nickstring ~= " (n1ckn4m3)";
        immutable expected = "[chan] [#nickname:123] < [#sub:456] " ~ nickstring ~ ` alt alt alt alt`;
        assertMultilineEquals(actual: line, expected: expected);
        //sink.clear();
    }
}


// formatMessageColoured
/++
    Formats an [dialect.defs.IRCEvent|IRCEvent] into an output range sink, coloured.

    It formats the timestamp, the type of the event, the sender or the sender's
    display name, the channel or target, the content body, as well as auxiliary
    information and numbers.

    Params:
        plugin = Current [kameloso.plugins.printer.PrinterPlugin|PrinterPlugin].
        sink = Output range to format the [dialect.defs.IRCEvent|IRCEvent] into.
        event = The [dialect.defs.IRCEvent|IRCEvent] that is to be formatted.
        bellOnMention = Whether or not to emit a terminal bell when the bot's
            nickname is mentioned in chat.
        bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
version(Colours)
void formatMessageColoured(Sink)
    (PrinterPlugin plugin,
    auto ref Sink sink,
    /*const*/ IRCEvent event,
    const bool bellOnMention,
    const bool bellOnError)
{
    import kameloso.constants : DefaultColours;
    import kameloso.terminal.colours.defs : ANSICodeType, TerminalReset;
    import kameloso.terminal.colours : applyANSI;
    import std.range.primitives : isOutputRange;
    import std.uni : asLowerCase;

    static if (!isOutputRange!(Sink, char[]))
    {
        import std.format : format;

        enum pattern = "`%s` must be passed an output range of `char[]`";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    alias Bright = EventPrintingBright;
    alias Dark = EventPrintingDark;
    alias Timestamp = DefaultColours.TimestampColour;

    /++
        Outputs a terminal ANSI colour token based on the hash of the passed
        nickname.

        It gives each user a random yet consistent colour to their name.
     +/
    uint colourByHash(const string nickname)
    {
        import kameloso.irccolours : ircANSIColourMap;
        import kameloso.terminal.colours : getColourByHash;

        if (!plugin.settings.colourfulNicknames)
        {
            // Don't differentiate between sender and target? Consistency?
            return plugin.state.coreSettings.brightTerminal ?
                Bright.sender :
                Dark.sender;
        }

        return getColourByHash(nickname, plugin.state.coreSettings);
    }

    /++
        Outputs a terminal truecolour token based on the #RRGGBB value stored in
        `user.colour`.

        This is for Twitch servers that assign such values to users' messages.
        By catching it we can honour the setting by tinting users accordingly.
     +/
    void putUserColour(const IRCUser user, const bool byAccount = false)
    {
        version(TwitchSupport)
        {
            if (!user.isServer &&
                user.colour.length &&
                plugin.settings.truecolour &&
                plugin.state.coreSettings.extendedColours)
            {
                import kameloso.terminal.colours : applyTruecolour;
                import lu.conv : rgbFromHex;

                auto rgb = rgbFromHex(user.colour);
                sink.applyTruecolour(
                    rgb.r,
                    rgb.g,
                    rgb.b,
                    brightTerminal: plugin.state.coreSettings.brightTerminal,
                    normalise: plugin.settings.normaliseTruecolour);
                return;
            }
        }

        immutable name = user.isServer ?
            user.address :
            ((user.account.length && (byAccount || plugin.settings.colourByAccount)) ?
                user.account :
                user.nickname);

        sink.applyANSI(colourByHash(name), ANSICodeType.foreground);
    }

    /++
        Puts a string into the output range sink in inverted colours.
     +/
    void putInverted(const string toInvert)
    {
        import kameloso.terminal : TerminalToken;
        import kameloso.terminal.colours.defs : TerminalFormat, TerminalReset;

        enum tF = cast(char) TerminalToken.format;
        enum fR = cast(int) TerminalFormat.reverse;
        enum rI = cast(int) TerminalReset.invert;
        .put(sink, tF, '[', fR, 'm', toInvert, tF, '[', rI, 'm');
    }

    /++
        Writes the timestamp and type of the event to the output range sink.
     +/
    void putTimeAndType()
    {
        import lu.conv : toString;
        import std.algorithm.searching : startsWith;
        import std.datetime : DateTime;
        import std.datetime.systime : SysTime;

        immutable rawTypestring = event.type.toString;
        immutable typestring = rawTypestring.withoutTypePrefix;
        immutable timestampCode = plugin.state.coreSettings.brightTerminal ? Timestamp.bright : Timestamp.dark;

        sink.applyANSI(timestampCode, ANSICodeType.foreground);
        sink.put('[');

        (cast(DateTime) SysTime
            .fromUnixTime(event.time))
            .timeOfDay
            .toString(sink);

        sink.put(']');

        if ((event.type == IRCEvent.Type.ERROR) ||
            (event.type == IRCEvent.Type.TWITCH_ERROR) ||
            rawTypestring.startsWith("ERR_"))
        {
            sink.applyANSI(plugin.state.coreSettings.brightTerminal ? Bright.error : Dark.error);
        }
        else
        {
            if (plugin.state.coreSettings.brightTerminal)
            {
                immutable code = (event.type == IRCEvent.Type.QUERY) ? Bright.query : Bright.type;
                sink.applyANSI(code, ANSICodeType.foreground);
            }
            else
            {
                immutable code = (event.type == IRCEvent.Type.QUERY) ? Dark.query : Dark.type;
                sink.applyANSI(code, ANSICodeType.foreground);
            }
        }

        sink.put(" [");

        if (plugin.settings.uppercaseTypes)
        {
            sink.put(typestring);
        }
        else
        {
            sink.put(typestring.asLowerCase);
        }

        sink.put("] ");
    }

    /++
        Writes the channel name and any potential subchannel name to the output
        range sink.

        If the channel has an ID and the setting is enabled, it is also printed.
     +/
    void putChannels()
    {
        if (event.channel.name.length)
        {
            immutable channelCode = plugin.state.coreSettings.brightTerminal ?
                Bright.channel :
                Dark.channel;

            sink.applyANSI(channelCode, ANSICodeType.foreground);
            .put(sink, '[', event.channel.name);

            version(TwitchSupport)
            {
                if (plugin.settings.channelIDs && event.channel.id)
                {
                    .put(sink, ':', event.channel.id);
                }
            }

            sink.put("] ");

            if (event.subchannel.name.length && (event.subchannel.name != event.channel.name))
            {
                immutable arrowCode = plugin.state.coreSettings.brightTerminal ?
                    Bright.content :
                    Dark.content;

                sink.applyANSI(arrowCode, ANSICodeType.foreground);
                .put(sink, "< ");

                sink.applyANSI(channelCode, ANSICodeType.foreground);
                .put(sink, '[', event.subchannel.name);

                version(TwitchSupport)
                {
                    if (plugin.settings.channelIDs && event.subchannel.id)
                    {
                        .put(sink, ':', event.subchannel.id);
                    }
                }

                sink.put("] ");
            }
        }
    }

    /++
        Writes the sender's nickname, display name, account name, and badges
        to the output range sink.
     +/
    void putSender()
    {
        scope(exit) sink.applyANSI(TerminalReset.all, ANSICodeType.reset);

        bool putDisplayName;

        putUserColour(event.sender);

        if (event.sender.isServer)
        {
            sink.put(event.sender.address);
            return;
        }

        version(TwitchSupport)
        {
            if (event.sender.displayName.length)
            {
                import std.algorithm.comparison : equal;
                import std.uni : asLowerCase;

                sink.put(event.sender.displayName);
                putDisplayName = true;

                if (plugin.settings.classNames)
                {
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    .put(sink, '/', event.sender.class_);
                }

                if ((event.sender.displayName != event.sender.account) &&
                    !event.sender.displayName.asLowerCase.equal(event.sender.account))
                {
                    if (!plugin.settings.classNames)
                    {
                        sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    }

                    sink.put(" (");
                    putUserColour(event.sender, byAccount: true);
                    sink.put(event.sender.account);
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    sink.put(')');
                }
            }
        }

        if (!putDisplayName && event.sender.nickname.length)
        {
            // Can be no-nick special: [PING] *2716423853
            sink.put(event.sender.nickname);

            if (plugin.settings.classNames)
            {
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                .put(sink, '/', event.sender.class_);
            }
        }

        if (plugin.settings.accountNames)
        {
            // No need to check for nickname.length, I think
            if ((plugin.state.server.daemon != IRCServer.Daemon.twitch) &&
                event.sender.account.length)
            {
                if (!plugin.settings.classNames)
                {
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                }

                sink.put(" (");
                putUserColour(event.sender, byAccount: true);
                sink.put(event.sender.account);
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.put(')');
            }
        }

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                plugin.settings.twitchBadges &&
                event.sender.badges.length &&
                (event.sender.badges != "*"))
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
                    immutable code = plugin.state.coreSettings.brightTerminal ? Bright.badge : Dark.badge;
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    sink.applyANSI(code, ANSICodeType.foreground);
                    .put(sink, " [", event.sender.badges, ']');
                    break;
                }
            }
        }
    }

    /++
        Writes the target's nickname, display name, account name, and badges
        to the output range sink.
     +/
    void putTarget()
    {
        if (!event.target.nickname.length) return;

        scope(exit) sink.applyANSI(TerminalReset.all, ANSICodeType.reset);

        bool putArrow;
        bool putDisplayName;
        bool putColour;

        version(TwitchSupport)
        {
            with (IRCEvent.Type)
            switch (event.type)
            {
            case TWITCH_GIFTCHAIN:
            case TWITCH_PAYFORWARD:
                // Add more as they become apparent
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.put(" <- ");
                break;

            default:
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.put(" -> ");
                break;
            }

            putArrow = true;

            if (event.target.displayName.length)
            {
                import std.algorithm.comparison : equal;
                import std.uni : asLowerCase;

                if (!event.sender.isServer &&
                    (event.target.nickname == plugin.state.client.nickname))
                {
                    putInverted(event.target.displayName);
                }
                else
                {
                    putUserColour(event.target);
                    sink.put(event.target.displayName);
                    putColour = true;
                }

                putDisplayName = true;

                if (plugin.settings.classNames)
                {
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    .put(sink, '/', event.target.class_);
                }

                if ((event.target.displayName != event.target.account) &&
                    !event.target.displayName.asLowerCase.equal(event.target.account))
                {
                    if (!plugin.settings.classNames)
                    {
                        sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    }

                    sink.put(" (");
                    putUserColour(event.target, byAccount: true);
                    putColour = true;
                    sink.put(event.target.account);
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    sink.put(')');
                }
            }
        }

        if (!putArrow)
        {
            // No need to check isServer; target is never server
            sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
            sink.put(" -> ");
            putUserColour(event.target);
            putColour = true;
        }

        if (!putDisplayName)
        {
            if (!event.sender.isServer &&
                (event.target.nickname == plugin.state.client.nickname))
            {
                putInverted(event.target.nickname);
            }
            else
            {
                putUserColour(event.target);
                sink.put(event.target.nickname);
            }

            if (plugin.settings.classNames)
            {
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                .put(sink, '/', event.target.class_);
            }
        }

        if (plugin.settings.accountNames)
        {
            // No need to check for nickname.length, I think
            if ((plugin.state.server.daemon != IRCServer.Daemon.twitch) &&
                event.target.account.length)
            {
                if (!plugin.settings.classNames)
                {
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                }

                sink.put(" (");
                putUserColour(event.target, byAccount: true);
                sink.put(event.target.account);
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.put(')');
            }
        }

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                plugin.settings.twitchBadges &&
                event.target.badges.length &&
                (event.target.badges != "*"))
            {
                immutable code = plugin.state.coreSettings.brightTerminal ? Bright.badge : Dark.badge;
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.applyANSI(code, ANSICodeType.foreground);
                .put(sink, " [", event.target.badges, ']');
            }
        }
    }

    /++
        Writes the content of the event to the output range sink.
        If `isAltcontent` is `true`, the content is written in a different style,
        as befits the secondary message-ness of [IRCEvent.altcontent].
     +/
    void putContent(
        const string line,
        const string emotes,
        ref bool shouldBell,
        const bool isAltcontent = false)
    {
        import kameloso.terminal.colours.defs : ANSICodeType, TerminalBackground, TerminalForeground;
        import kameloso.terminal.colours : applyANSI;

        if (!line.length) return;

        scope(exit) sink.applyANSI(TerminalReset.all, ANSICodeType.reset);

        immutable TerminalForeground contentFgBase = plugin.state.coreSettings.brightTerminal ?
            Bright.content :
            Dark.content;
        immutable TerminalForeground emoteFgBase = plugin.state.coreSettings.brightTerminal ?
            Bright.emote :
            Dark.emote;
        immutable isEmote =
            !isAltcontent &&  // we can't really tell but treat altcontent as always non-emote
            ((event.type == IRCEvent.Type.EMOTE) ||
            (event.type == IRCEvent.Type.SELFEMOTE));
        immutable fgBase = isEmote ? emoteFgBase : contentFgBase;

        //sink.applyANSI(TerminalReset.all, ANSICodeType.reset);  // do we need this?
        sink.applyANSI(fgBase, ANSICodeType.foreground);  // Always grey colon and SASL +, prepare for emote

        if (!event.sender.isServer && !event.sender.nickname.length)
        {
            // PING or ERROR likely
            sink.put(line);  // No need for delimiter space
            return;
        }

        string content = line;  // mutable
        bool openQuote;

        if (isAltcontent)
        {
            if (event.target.nickname.length)
            {
                sink.put(`: "`);
                openQuote = true;
            }
            else if (event.content.length)
            {
                sink.put(" | ");
            }
            else
            {
                sink.put(' ');
            }
        }
        else
        {
            if (isEmote)
            {
                sink.put(' ');
            }
            else
            {
                sink.put(`: "`);
                openQuote = true;
            }
        }

        if (plugin.state.server.daemon != IRCServer.Daemon.twitch)
        {
            import kameloso.irccolours : mapEffects;
            // Twitch chat has no colours or effects, only emotes
            content = mapEffects(content, fgBase);
        }
        else
        {
            version(TwitchSupport)
            {
                content = highlightEmotes(
                    line: content,
                    emotes: emotes,
                    type: event.type,
                    colourful: plugin.settings.colourfulEmotes,
                    coreSettings: plugin.state.coreSettings);
            }
        }

        with (IRCEvent.Type)
        switch (event.type)
        {
        case CHAN:
        case EMOTE:
        case TWITCH_SUBGIFT:
        case TWITCH_SUB:
        case TWITCH_ANNOUNCEMENT:
        case TWITCH_CHEER:
        case CLEARMSG:
        //case SELFCHAN:
            import kameloso.terminal.colours : invert;

            /// Nick was mentioned (certain)
            bool match;
            string inverted = content;

            if (content.containsNickname(plugin.state.client.nickname))
            {
                inverted = content.invert(plugin.state.client.nickname, match);
            }

            version(TwitchSupport)
            {
                // If available, also highlight the display name alias
                if (plugin.state.client.displayName.length &&
                    (plugin.state.client.nickname != plugin.state.client.displayName) &&
                    content.containsNickname(plugin.state.client.displayName))
                {
                    bool displayNameMatch;
                    inverted = inverted.invert(plugin.state.client.displayName, displayNameMatch);
                    match |= displayNameMatch;
                }
            }

            if (match)
            {
                sink.put(inverted);
                shouldBell = bellOnMention;
                break;
            }
            else
            {
                goto default;
            }

        default:
            sink.put(content);
            break;
        }

        // Reset the background to ward off bad backgrounds bleeding out
        sink.applyANSI(fgBase, ANSICodeType.foreground); //, TerminalBackground.default_);
        sink.applyANSI(TerminalBackground.default_);

        if (openQuote) sink.put('"');
    }

    /++
        Writes the auxiliary information of the event to the output range sink.
     +/
    void putAux()
    {
        import std.algorithm.iteration : filter;
        import std.format : formattedWrite;

        auto auxRange = event.aux[].filter!(s => s.length);
        if (!auxRange.empty)
        {
            enum pattern = " (%-(%s%|) (%))";
            sink.applyANSI(plugin.state.coreSettings.brightTerminal ? Bright.aux : Dark.aux);
            sink.formattedWrite(pattern, auxRange);
        }
    }

    /++
        Writes the count information of the event to the output range sink.
     +/
    void putCount()
    {
        import std.algorithm.iteration : filter;
        import std.format : formattedWrite;

        auto countRange = event.count[].filter!(n => !n.isNull);
        if (!countRange.empty)
        {
            enum pattern = " {%-(%s%|} {%)}";
            sink.applyANSI(plugin.state.coreSettings.brightTerminal ? Bright.count : Dark.count);
            sink.formattedWrite(pattern, countRange);
        }
    }

    /++
        Writes the numerical ID of the event to the output range sink.
     +/
    void putNum()
    {
        if (event.num > 0)
        {
            import lu.conv : toAlphaInto;

            sink.applyANSI(plugin.state.coreSettings.brightTerminal ? Bright.num : Dark.num);
            sink.put(" [#");
            event.num.toAlphaInto!(3, 3)(sink);
            sink.put(']');
        }
    }

    /++
        Writes any errors that occurred during parsing or postprocessing of the
        event to the output range sink.
     +/
    void putErrors()
    {
        if (event.errors.length)
        {
            immutable code = plugin.state.coreSettings.brightTerminal ? Bright.error : Dark.error;
            sink.applyANSI(code, ANSICodeType.foreground);
            .put(sink, " ! ", event.errors, " !");
        }
    }

    ////////////////////////////////////////////////////////////////////////////

    static if (!__traits(hasMember, Sink, "data"))
    {
        // May be a lockingTextWriter and the content won't be writeln'd
        scope(exit) sink.put('\n');
    }

    bool shouldBell;

    putTimeAndType();

    putChannels();

    putSender();

    version(TwitchSupport) immutable emotes = event.emotes;
    else immutable emotes = string.init;

    putContent(
        line: event.content,
        emotes: emotes,
        shouldBell: shouldBell);

    putTarget();

    if (event.altcontent.length)
    {
        putContent(
            line: event.altcontent,
            emotes: event.aux[$-2],
            shouldBell: shouldBell,
            isAltcontent: true);
        event.aux[$-2] = string.init;  // Remove any custom emote definitions
    }

    putAux();

    putCount();

    putNum();

    putErrors();

    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);

    shouldBell |=
        ((event.type == IRCEvent.Type.QUERY) && bellOnMention) ||
        (event.errors.length && bellOnError);

    if (shouldBell) sink.put(plugin.transient.bell);
}


// withoutTypePrefix
/++
    Slices away any type prefixes from the string name of an
    [dialect.defs.IRCEvent.Type|IRCEvent.Type].

    Only for shared use in [formatMessageMonochrome] and [formatMessageColoured].

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
        typestring = The string form of a [dialect.defs.IRCEvent.Type|IRCEvent.Type].

    Returns:
        A slice of the passed `typestring`, excluding any prefixes if present.
 +/
private auto withoutTypePrefix(const string typestring) pure @safe
{
    import std.algorithm.searching : startsWith;
    import std.meta : AliasSeq;

    alias typePrefixes = AliasSeq!("RPL_", "ERR_", "TWITCH_");

    version(TwitchSupport)
    {
        immutable typePrefixIndex = typestring.startsWith(typePrefixes);
    }
    else
    {
        immutable typePrefixIndex = typestring.startsWith(typePrefixes[0..2]);
    }

    version(TwitchSupport)
    {
        if (typePrefixIndex == 3)
        {
            // TWITCH_
            return typestring[7..$];
        }
    }

    if (typePrefixIndex != 0)
    {
        // RPL_ or ERR_
        return typestring[4..$];
    }
    else
    {
        return typestring;  // as is
    }
}

///
unittest
{
    {
        enum typestring = "RPL_ENDOFMOTD";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "ENDOFMOTD"), without);
    }
    {
        enum typestring = "ERR_CHANOPRIVSNEEDED";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "CHANOPRIVSNEEDED"), without);
    }
    version(TwitchSupport)
    {{
        enum typestring = "TWITCH_SUB";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "SUB"), without);
    }}
    {
        enum typestring = "PRIVMSG";
        immutable without = typestring.withoutTypePrefix;
        assert((without == "PRIVMSG"), without);
    }
}


// highlightEmotes
/++
    Tints emote strings and highlights Twitch emotes in a string.

    A [dialect.defs.IRCEvent.Type|IRCEvent.Type] must be provided to put the
    colour in context; if it is an `EMOTE`- (or `SELFEMOTE`)-type event, the
    colour of non-emote text will be different.

    Wraps [highlightEmotesImpl].

    Params:
        line = The text in which to highlight emotes.
        emotes = The list of emotes and their positions as divined from the
            IRCv3 tags of an event.
        type = The type of the event.
        colourful = Whether or not emotes should be highlighted in colours.
        coreSettings = Current [kameloso.pods.CoreSettings|settings].

    Returns:
        A new string of the passed [dialect.defs.IRCEvent|IRCEvent]'s `content` member
        with any emotes highlighted, or said `content` member as-is if there weren't any.
 +/
version(Colours)
version(TwitchSupport)
auto highlightEmotes(
    const string line,
    const string emotes,
    const IRCEvent.Type type,
    const bool colourful,
    const CoreSettings coreSettings)
{
    import kameloso.constants : DefaultColours;
    import std.array : Appender;
    import std.exception : assumeUnique;

    alias Bright = EventPrintingBright;
    alias Dark = EventPrintingDark;

    if (!emotes.length) return line;

    static Appender!(char[]) sink;
    scope(exit) sink.clear();
    sink.reserve(line.length + 60);  // guesttimate, mostly +10

    immutable TerminalForeground highlight = coreSettings.brightTerminal ?
        Bright.highlight :
        Dark.highlight;

    immutable TerminalForeground contentFgBase = coreSettings.brightTerminal ?
        Bright.content :
        Dark.content;

    immutable TerminalForeground emoteFgBase = coreSettings.brightTerminal ?
        Bright.emote :
        Dark.emote;

    immutable baseColour = (type == IRCEvent.Type.EMOTE) || (type == IRCEvent.Type.SELFEMOTE) ?
        emoteFgBase :
        contentFgBase;

    sink.highlightEmotesImpl(
        line: line,
        emotes: emotes,
        pre: highlight,
        post: baseColour,
        colourful: colourful,
        coreSettings: coreSettings);

    return sink[].assumeUnique();
}


// highlightEmotesImpl
/++
    Highlights Twitch emotes in the chat by tinting them a different colour,
    saving the results into a passed output range sink.

    Params:
        sink = Output range to put the results into.
        line = Content line containing emotes that should be highlighted.
        emotes = The list of emotes and their positions as divined from the
            IRCv3 tags of an event.
        pre = Terminal foreground tint to colour the emotes with.
        post = Terminal foreground tint to reset to after colouring an emote.
        colourful = Whether or not emotes should be highlighted in colours.
        coreSettings = Current [kameloso.pods.CoreSettings|settings].
 +/
version(Colours)
version(TwitchSupport)
void highlightEmotesImpl(Sink)
    (auto ref Sink sink,
    const string line,
    const string emotes,
    const TerminalForeground pre,
    const TerminalForeground post,
    const bool colourful,
    const CoreSettings coreSettings)
{
    import std.algorithm.iteration : splitter, uniq;
    import std.algorithm.sorting : sort;
    import std.array : Appender;
    import std.conv : to;
    import std.range.primitives : isOutputRange;

    static if (!isOutputRange!(Sink, char[]))
    {
        import std.format : format;

        enum pattern = "`%s` must be passed an output range of `char[]`";
        enum message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    static struct Highlight
    {
        string id;
        size_t start;
        size_t end;
    }

    // max encountered emotes so far: 46
    // Severely pathological let's-crash-the-bot case: max possible ~161 emotes
    // That is a standard PRIVMSG line with ":) " repeated until 512 chars.
    //enum maxHighlights = 162;

    static Appender!(Highlight[]) highlights;

    scope(exit)
    {
        if (highlights[].length)
        {
            highlights.clear();
        }
    }

    if (highlights.capacity == 0)
    {
        highlights.reserve(64);  // guesstimate
    }

    size_t pos;

    foreach (/*const*/ emote; emotes.splitter('/'))
    {
        import lu.string : advancePast;

        immutable emoteID = emote.advancePast(':');

        foreach (immutable location; emote.splitter(','))
        {
            import std.string : indexOf;

            immutable dashPos = location.indexOf('-');
            immutable start = location[0..dashPos].to!size_t;
            immutable end = location[dashPos+1..$].to!size_t + 1;  // inclusive

            highlights.put(Highlight(emoteID, start, end));
        }
    }

    /+
        We need to use uniq since sometimes there will be custom emotes for which
        there are already official ones. Example:

            content: Hey Dist, what’s up? distPls distRoll
            emotes:  emotesv2_1e80339255a84a4ebbd0129851b90aa0:21-27/emotesv2_744f13dfe4a345c5be4becdeb05343ee:29-36/distPls:21-27

        The first and the last are duplicates.
     +/
    auto sortedHighlights = highlights[]
        //.dup
        .sort!((a, b) => (a.start < b.start))
        .uniq!((a, b) => (a.start == b.start)); // && (a.end == b.end));

    // We need a dstring since we're slicing something that isn't necessarily ASCII
    // Without this highlights become offset a few characters depending on the text
    immutable dline = line.to!dstring;

    foreach (const highlight; sortedHighlights)
    {
        import kameloso.terminal.colours.defs : ANSICodeType;
        import kameloso.terminal.colours : applyANSI, getColourByHash;

        immutable colour = colourful ?
            getColourByHash(highlight.id, coreSettings) :
            pre;

        sink.put(dline[pos..highlight.start]);
        sink.applyANSI(colour, ANSICodeType.foreground);
        sink.put(dline[highlight.start..highlight.end]);
        sink.applyANSI(post, ANSICodeType.foreground);
        pos = highlight.end;
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

    CoreSettings brightSettings;
    CoreSettings darkSettings;
    brightSettings.brightTerminal = true;

    {
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: false, darkSettings);
        assert((sink[] == "Moody the god \033[97mpownyFine\033[39m \033[97mpownyL\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: false, darkSettings);
        assert((sink[] == "whoever plays nintendo switch whisper me \033[97mKappa\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: false, darkSettings);
        assert((sink[] == "NOOOOOO \033[97mcamillsCry\033[39m " ~
            "\033[97mcamillsCry\033[39m \033[97mcamillsCry\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "822112:0-6,8-14,16-22";
        immutable line = "FortOne FortOne FortOne";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: false, darkSettings);
        assert((sink[] == "\033[97mFortOne\033[39m \033[97mFortOne\033[39m " ~
            "\033[97mFortOne\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "141844:17-24,26-33,35-42/141073:9-15";
        immutable line = "@mugs123 cohhWow cohhBoop cohhBoop cohhBoop";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: false, darkSettings);
        assert((sink[] == "@mugs123 \033[97mcohhWow\033[39m \033[97mcohhBoop\033[39m " ~
            "\033[97mcohhBoop\033[39m \033[97mcohhBoop\033[39m"), sink[]);
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
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: false, brightSettings);
        assert((sink[] == highlitLine), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "25:32-36";
        immutable line = "@kiwiskool but you’re a sub too Kappa";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: false, brightSettings);
        assert((sink[] == "@kiwiskool but you’re a sub too \033[97mKappa\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: false, brightSettings);
        assert((sink[] == "高所恐怖症 \033[97mLUL\033[39m なにぬねの " ~
            "\033[97mLUL\033[39m \033[97m:)\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: true, brightSettings);
        assert((sink[] == "高所恐怖症 \033[38;5;171mLUL\033[39m なにぬねの " ~
            "\033[38;5;171mLUL\033[39m \033[35m:)\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: true, brightSettings);
        assert((sink[] == "Moody the god \033[38;5;237mpownyFine\033[39m \033[38;5;159mpownyL\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: true, brightSettings);
        assert((sink[] == "whoever plays nintendo switch whisper me \033[38;5;49mKappa\033[39m"), sink[]);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, colourful: true, brightSettings);
        assert((sink[] == "NOOOOOO \033[38;5;166mcamillsCry\033[39m " ~
            "\033[38;5;166mcamillsCry\033[39m \033[38;5;166mcamillsCry\033[39m"), sink[]);
    }
}


// containsNickname
/++
    Searches a string for a substring that isn't surrounded by characters that
    can be part of a nickname. This can detect a nickname in a string without
    getting false positives from similar nicknames.

    Tries to detect nicknames enclosed in terminal formatting. As such, call this
    *after* having translated IRC-to-terminal such with
    [kameloso.irccolours.mapEffects].

    Uses [std.string.indexOf|indexOf] internally with hopes of being more resilient to
    weird UTF-8.

    Params:
        haystack = A string to search for the substring nickname.
        needle = The nickname substring to find in `haystack`.

    Returns:
        True if `haystack` contains `needle` in such a way that it is guaranteed
        to not be a different nickname.
 +/
auto containsNickname(const string haystack, const string needle) pure @safe nothrow @nogc
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

/++
    Implementation of Printer plugin functionality that concerns formatting.
    For internal use.

    The [dialect.defs.IRCEvent|IRCEvent]-annotated handlers must be in the same module
    as the [kameloso.plugins.printer.base.PrinterPlugin|PrinterPlugin],
    but these implementation functions can be offloaded here to limit module size a bit.

    See_Also:
        [kameloso.plugins.printer.base],
        [kameloso.plugins.printer.logging]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.printer.formatting;

version(WithPrinterPlugin):

private:

import kameloso.plugins.printer.base;

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
        immutable message = pattern.format(__FUNCTION__);
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
            import lu.conv : Enum;
            import std.traits : Unqual;

            sink.put(Enum!(Unqual!T).toString(arg));
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
    assert((sink.data == "abc-9223372036854775808def456true"), sink.data);
}


// formatMessageMonochrome
/++
    Formats an [dialect.defs.IRCEvent|IRCEvent] into an output range sink, in monochrome.

    It formats the timestamp, the type of the event, the sender or sender alias,
    the channel or target, the content body, as well as auxiliary information.

    Params:
        plugin = Current [kameloso.plugins.printer.base.PrinterPlugin|PrinterPlugin].
        sink = Output range to format the [dialect.defs.IRCEvent|IRCEvent] into.
        event = The [dialect.defs.IRCEvent|IRCEvent] that is to be formatted.
        bellOnMention = Whether or not to emit a terminal bell when the bot's
            nickname is mentioned in chat.
        bellOnError = Whether or not to emit a terminal bell when an error occurred.
 +/
void formatMessageMonochrome(Sink)
    (PrinterPlugin plugin,
    auto ref Sink sink,
    const ref IRCEvent event,
    const Flag!"bellOnMention" bellOnMention,
    const Flag!"bellOnError" bellOnError)
{
    import kameloso.irccolours : stripEffects;
    import lu.conv : Enum;
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : filter;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;
    import std.range.primitives : isOutputRange;
    import std.uni : asLowerCase;

    static if (!isOutputRange!(Sink, char[]))
    {
        import std.format : format;

        enum pattern = "`%s` must be passed an output range of `char[]`";
        immutable message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    immutable typestring = Enum!(IRCEvent.Type).toString(event.type).withoutTypePrefix;
    immutable content = stripEffects(event.content);
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
            return;
        }

        bool putDisplayName;

        version(TwitchSupport)
        {
            if (event.sender.displayName.length)
            {
                sink.put(event.sender.displayName);
                putDisplayName = true;

                if (plugin.printerSettings.classNames)
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

            if (plugin.printerSettings.classNames)
            {
                .put(sink, '/', event.sender.class_);
            }
        }

        if (plugin.printerSettings.accountNames)
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

    void putTarget()
    {
        bool putArrow;
        bool putDisplayName;

        version(TwitchSupport)
        {
            with (IRCEvent.Type)
            switch (event.type)
            {
            case TWITCH_GIFTCHAIN:
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
                sink.put(event.target.displayName);
                putDisplayName = true;

                if (plugin.printerSettings.classNames)
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

            if (plugin.printerSettings.classNames)
            {
                .put(sink, '/', event.target.class_);
            }
        }

        if (plugin.printerSettings.accountNames)
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
                    content.containsNickname(plugin.state.client.nickname))
                {
                    // Nick was mentioned (certain)
                    shouldBell = bellOnMention;
                }
                break;

            default:
                break;
            }

            sink.put(content);
            if (!isEmote) sink.put('"');
        }
        else
        {
            // PING or ERROR likely
            sink.put(content);  // No need for indenting space
        }
    }

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

    bool putQuotedTwitchMessage;
    string[event.aux.length] auxCopy = event.aux;

    version(TwitchSupport)
    {
        import std.algorithm.comparison : among;

        immutable isEmotePossibleEventType = event.type.among!
            (IRCEvent.Type.CHAN,
            IRCEvent.Type.EMOTE,
            IRCEvent.Type.SELFCHAN,
            IRCEvent.Type.SELFEMOTE);

        if (isEmotePossibleEventType &&
            event.target.nickname.length &&
            (event.aux[0].length))
        {
            /*if (content.length)*/ putContent();
            putTarget();
            .put(sink, `: "`, event.aux[0], '"');
            putQuotedTwitchMessage = true;
            auxCopy[0] = string.init;
        }
    }

    if (!putQuotedTwitchMessage)
    {
        if (event.target.nickname.length) putTarget();
        if (content.length) putContent();
    }

    // Base the range on the modified copy
    auto auxRange = auxCopy[].filter!(s => s.length);
    if (!auxRange.empty)
    {
        enum pattern = " (%-(%s%|) (%))";

        static if ((__VERSION__ >= 2099L) && (__VERSION__ <= 2102L))
        {
            import std.array : array;
            // "Deprecation: scope variable `aux` assigned to non-scope parameter `_param_2` calling `formattedWrite"
            // Seemingly only between 2.099 and 2.102
            sink.formattedWrite(pattern, auxRange.array.dup);
        }
        else
        {
            sink.formattedWrite(pattern, auxRange);
        }
    }

    auto countRange = event.count[].filter!(n => !n.isNull);
    if (!countRange.empty)
    {
        enum pattern = " {%-(%s%|} {%)}";
        sink.formattedWrite(pattern, countRange);
    }

    if (event.num > 0)
    {
        import lu.conv : toAlphaInto;

        sink.put(" [#");
        event.num.toAlphaInto!(3, 3)(sink);
        sink.put(']');
    }

    if (event.errors.length)
    {
        .put(sink, " ! ", event.errors, " !");
    }

    shouldBell = shouldBell ||
        ((event.type == IRCEvent.Type.QUERY) && bellOnMention) ||
        (event.errors.length && bellOnError);

    if (shouldBell) sink.put(plugin.transient.bell);
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
        account = "n1ckn4m3";
        class_ = IRCUser.Class.whitelist;
    }

    event.type = IRCEvent.Type.JOIN;
    event.channel = "#channel";

    {
        formatMessageMonochrome(plugin, sink, event, No.bellOnMention, No.bellOnError);
        immutable joinLine = sink.data[11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        //nickstring ~= "/whitelist";
        immutable expected = "[join] [#channel] " ~ nickstring;
        assert((joinLine == expected), joinLine);
        sink.clear();
    }

    event.type = IRCEvent.Type.CHAN;
    event.content = "Harbl snarbl";

    {
        formatMessageMonochrome(plugin, sink, event, No.bellOnMention, No.bellOnError);
        immutable chanLine = sink.data[11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        //nickstring ~= "/whitelist";
        immutable expected = "[chan] [#channel] " ~ nickstring ~ `: "Harbl snarbl"`;
        assert((chanLine == expected), chanLine);
        sink.clear();
    }

    plugin.printerSettings.classNames = true;
    event.sender.badges = "broadcaster/0,moderator/1,subscriber/9";
    event.sender.class_ = IRCUser.Class.staff;
    //colour = "#3c507d";

    version(TwitchSupport)
    {{
        formatMessageMonochrome(plugin, sink, event, No.bellOnMention, No.bellOnError);
        immutable twitchLine = sink.data[11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        nickstring ~= "/staff";
        immutable expected = "[chan] [#channel] " ~ nickstring ~
            ` [broadcaster/0,moderator/1,subscriber/9]: "Harbl snarbl"`;
        assert((twitchLine == expected), twitchLine);
        sink.clear();
        event.sender.badges = string.init;
    }}

    plugin.printerSettings.accountNames = true;
    plugin.state.server.daemon = IRCServer.Daemon.inspircd;
    event.sender.class_ = IRCUser.Class.anyone;
    event.type = IRCEvent.Type.ACCOUNT;
    event.channel = string.init;
    event.content = string.init;
    //event.sender.account = "n1ckn4m3";
    event.aux[0] = "n1ckn4m3";

    {
        formatMessageMonochrome(plugin, sink, event, No.bellOnMention, No.bellOnError);
        immutable accountLine = sink.data[11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        nickstring ~= "/anyone";
        nickstring ~= " (n1ckn4m3)";
        immutable expected = "[account] " ~ nickstring ~ " (n1ckn4m3)";
        assert((accountLine == expected), accountLine);
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
        formatMessageMonochrome(plugin, sink, event, No.bellOnMention, No.bellOnError);
        immutable errorLine = sink.data[11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        nickstring ~= "/anyone";
        nickstring ~= " (n1ckn4m3)";
        immutable expected = "[error] " ~ nickstring ~ `: "Blah balah" (aux1) (aux5) ` ~
            "{-42} {123} {420} [#666] ! DANGER WILL ROBINSON !";
        assert((errorLine == expected), errorLine);
        sink.clear();
    }

    plugin.printerSettings.classNames = false;
    event.type = IRCEvent.Type.CHAN;
    event.channel = "#nickname";
    event.num = 0;
    event.count = typeof(IRCEvent.count).init;
    event.aux = typeof(IRCEvent.aux).init;
    event.errors = string.init;

    {
        formatMessageMonochrome(plugin, sink, event, No.bellOnMention, No.bellOnError);
        immutable queryLine = sink.data[11..$].idup;
        version(TwitchSupport) string nickstring = "Nickname";
        else string nickstring = "nickname";
        //nickstring ~= "/anyone";
        nickstring ~= " (n1ckn4m3)";
        immutable expected = "[chan] [#nickname] " ~ nickstring ~ `: "Blah balah"`;
        assert((queryLine == expected), queryLine);
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
        plugin = Current [kameloso.plugins.printer.base.PrinterPlugin|PrinterPlugin].
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
    const ref IRCEvent event,
    const Flag!"bellOnMention" bellOnMention,
    const Flag!"bellOnError" bellOnError)
{
    import kameloso.constants : DefaultColours;
    import kameloso.terminal.colours.defs : ANSICodeType, TerminalReset;
    import kameloso.terminal.colours : applyANSI;
    import lu.conv : Enum;
    import std.algorithm.iteration : filter;
    import std.algorithm.searching : startsWith;
    import std.datetime : DateTime;
    import std.datetime.systime : SysTime;
    import std.format : formattedWrite;
    import std.range.primitives : isOutputRange;
    import std.uni : asLowerCase;

    static if (!isOutputRange!(Sink, char[]))
    {
        import std.format : format;

        enum pattern = "`%s` must be passed an output range of `char[]`";
        immutable message = pattern.format(__FUNCTION__);
        static assert(0, message);
    }

    alias Bright = EventPrintingBright;
    alias Dark = EventPrintingDark;
    alias Timestamp = DefaultColours.TimestampColour;

    immutable rawTypestring = Enum!(IRCEvent.Type).toString(event.type);
    immutable typestring = rawTypestring.withoutTypePrefix;
    string content = event.content;  // mutable, don't strip
    bool shouldBell;

    immutable bright = cast(Flag!"brightTerminal")plugin.state.settings.brightTerminal;

    /++
        Outputs a terminal ANSI colour token based on the hash of the passed
        nickname.

        It gives each user a random yet consistent colour to their name.
     +/
    uint colourByHash(const string nickname)
    {
        import kameloso.irccolours : ircANSIColourMap;
        import kameloso.terminal.colours : getColourByHash;

        if (!plugin.printerSettings.colourfulNicknames)
        {
            // Don't differentiate between sender and target? Consistency?
            return plugin.state.settings.brightTerminal ? Bright.sender : Dark.sender;
        }

        return getColourByHash(nickname, plugin.state.settings);
    }

    /++
        Outputs a terminal truecolour token based on the #RRGGBB value stored in
        `user.colour`.

        This is for Twitch servers that assign such values to users' messages.
        By catching it we can honour the setting by tinting users accordingly.
     +/
    void colourUserTruecolour(const IRCUser user)
    {
        bool coloured;

        version(TwitchSupport)
        {
            if (!user.isServer &&
                user.colour.length &&
                plugin.printerSettings.truecolour &&
                plugin.state.settings.extendedColours)
            {
                import kameloso.terminal.colours : applyTruecolour;
                import lu.conv : rgbFromHex;

                auto rgb = rgbFromHex(user.colour);
                sink.applyTruecolour(
                    rgb.r,
                    rgb.g,
                    rgb.b,
                    bright,
                    cast(Flag!"normalise")plugin.printerSettings.normaliseTruecolour);
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

            sink.applyANSI(colourByHash(name), ANSICodeType.foreground);
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
        scope(exit) sink.applyANSI(TerminalReset.all, ANSICodeType.reset);

        bool putDisplayName;

        colourUserTruecolour(event.sender);

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

                if (plugin.printerSettings.classNames)
                {
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    .put(sink, '/', event.sender.class_);
                }

                if ((event.sender.displayName != event.sender.nickname) &&
                    !event.sender.displayName.asLowerCase.equal(event.sender.nickname))
                {
                    if (!plugin.printerSettings.classNames)
                    {
                        sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    }

                    sink.put(" (");
                    colourUserTruecolour(event.sender);
                    sink.put(event.sender.nickname);
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    sink.put(')');
                }
            }
        }

        if (!putDisplayName && event.sender.nickname.length)
        {
            // Can be no-nick special: [PING] *2716423853
            sink.put(event.sender.nickname);

            if (plugin.printerSettings.classNames)
            {
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                .put(sink, '/', event.sender.class_);
            }
        }

        if (plugin.printerSettings.accountNames)
        {
            // No need to check for nickname.length, I think
            if ((plugin.state.server.daemon != IRCServer.Daemon.twitch) &&
                event.sender.account.length)
            {
                immutable code = bright ? Bright.account : Dark.account;
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.applyANSI(code, ANSICodeType.foreground);
                .put(sink, " (", event.sender.account, ')');
            }
        }

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                plugin.printerSettings.twitchBadges &&
                event.sender.badges.length)
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
                    immutable code = bright ? Bright.badge : Dark.badge;
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    sink.applyANSI(code, ANSICodeType.foreground);
                    .put(sink, " [", event.sender.badges, ']');
                    break;
                }
            }
        }
    }

    void putTarget()
    {
        scope(exit) sink.applyANSI(TerminalReset.all, ANSICodeType.reset);

        bool putArrow;
        bool putDisplayName;

        version(TwitchSupport)
        {
            with (IRCEvent.Type)
            switch (event.type)
            {
            case TWITCH_GIFTCHAIN:
                // Add more as they become apparent
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.put(" <- ");
                break;

            default:
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.put(" -> ");
                break;
            }

            colourUserTruecolour(event.target);
            putArrow = true;

            if (event.target.displayName.length)
            {
                import std.algorithm.comparison : equal;
                import std.uni : asLowerCase;

                sink.put(event.target.displayName);
                putDisplayName = true;

                if (plugin.printerSettings.classNames)
                {
                    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    .put(sink, '/', event.target.class_);
                }

                if ((event.target.displayName != event.target.nickname) &&
                    !event.target.displayName.asLowerCase.equal(event.target.nickname))
                {
                    if (!plugin.printerSettings.classNames)
                    {
                        sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                    }

                    sink.put(" (");
                    colourUserTruecolour(event.target);
                    sink.put(event.target.nickname);
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
            colourUserTruecolour(event.target);
        }

        if (!putDisplayName)
        {
            sink.put(event.target.nickname);

            if (plugin.printerSettings.classNames)
            {
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                .put(sink, '/', event.target.class_);
            }
        }

        if (plugin.printerSettings.accountNames)
        {
            // No need to check for nickname.length, I think
            if ((plugin.state.server.daemon != IRCServer.Daemon.twitch) &&
                event.target.account.length)
            {
                immutable code = bright ? Bright.account : Dark.account;
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.applyANSI(code, ANSICodeType.foreground);
                .put(sink, " (", event.target.account, ')');
            }
        }

        version(TwitchSupport)
        {
            if ((plugin.state.server.daemon == IRCServer.Daemon.twitch) &&
                plugin.printerSettings.twitchBadges &&
                event.target.badges.length)
            {
                immutable code = bright ? Bright.badge : Dark.badge;
                sink.applyANSI(TerminalReset.all, ANSICodeType.reset);
                sink.applyANSI(code, ANSICodeType.foreground);
                .put(sink, " [", event.target.badges, ']');
            }
        }
    }

    void putContent()
    {
        import kameloso.terminal.colours.defs : ANSICodeType, TerminalBackground, TerminalForeground;
        import kameloso.terminal.colours : applyANSI;

        scope(exit) sink.applyANSI(TerminalReset.all, ANSICodeType.reset);

        immutable TerminalForeground contentFgBase = bright ? Bright.content : Dark.content;
        immutable TerminalForeground emoteFgBase = bright ? Bright.emote : Dark.emote;
        immutable isEmote =
            (event.type == IRCEvent.Type.EMOTE) ||
            (event.type == IRCEvent.Type.SELFEMOTE);
        immutable fgBase = isEmote ? emoteFgBase : contentFgBase;

        //sink.applyANSI(TerminalReset.all, ANSICodeType.reset);  // do we need this?
        sink.applyANSI(fgBase, ANSICodeType.foreground);  // Always grey colon and SASL +, prepare for emote

        if (!event.sender.isServer && !event.sender.nickname.length)
        {
            // PING or ERROR likely
            sink.put(content);  // No need for delimiter space
            return;
        }

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
            import kameloso.irccolours : mapEffects;
            // Twitch chat has no colours or effects, only emotes
            content = mapEffects(content, fgBase);
        }
        else
        {
            version(TwitchSupport)
            {
                content = highlightEmotes(
                    event,
                    cast(Flag!"colourful")plugin.printerSettings.colourfulEmotes,
                    plugin.state.settings);
            }
        }

        with (IRCEvent.Type)
        switch (event.type)
        {
        case CHAN:
        case EMOTE:
        case TWITCH_SUBGIFT:
        //case SELFCHAN:
            import kameloso.terminal.colours : invert;

            /// Nick was mentioned (certain)
            bool match;
            string inverted = content;

            if (content.containsNickname(plugin.state.client.nickname))
            {
                inverted = content.invert(plugin.state.client.nickname);
                match = true;
            }

            version(TwitchSupport)
            {
                // If available, also highlight the display name alias
                if (plugin.state.client.displayName.length &&
                    (plugin.state.client.nickname != plugin.state.client.displayName) &&
                    content.containsNickname(plugin.state.client.displayName))
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
            sink.put(content);
            break;
        }

        // Reset the background to ward off bad backgrounds bleeding out
        sink.applyANSI(fgBase, ANSICodeType.foreground); //, TerminalBackground.default_);
        sink.applyANSI(TerminalBackground.default_);
        if (!isEmote) sink.put('"');
    }

    immutable timestampCode = bright ? Timestamp.bright : Timestamp.dark;
    sink.applyANSI(timestampCode, ANSICodeType.foreground);
    sink.put('[');

    (cast(DateTime)SysTime
        .fromUnixTime(event.time))
        .timeOfDay
        .toString(sink);

    sink.put(']');

    if ((event.type == IRCEvent.Type.ERROR) ||
        (event.type == IRCEvent.Type.TWITCH_ERROR) ||
        rawTypestring.startsWith("ERR_"))
    {
        sink.applyANSI(bright ? Bright.error : Dark.error);
    }
    else
    {
        if (bright)
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
        immutable code = bright ? Bright.channel : Dark.channel;
        sink.applyANSI(code, ANSICodeType.foreground);
        .put(sink, '[', event.channel, "] ");
    }

    putSender();

    bool putQuotedTwitchMessage;
    string[event.aux.length] auxCopy = event.aux;

    version(TwitchSupport)
    {
        import std.algorithm.comparison : among;

        immutable isEmotePossibleEventType = event.type.among!
            (IRCEvent.Type.CHAN,
            IRCEvent.Type.EMOTE,
            IRCEvent.Type.SELFCHAN,
            IRCEvent.Type.SELFEMOTE);

        if (isEmotePossibleEventType &&
            event.content.length &&
            event.target.nickname.length &&
            event.aux[0].length)
        {
            /*if (content.length)*/ putContent();
            putTarget();
            immutable code = bright ? Bright.content : Dark.content;
            sink.applyANSI(code, ANSICodeType.foreground);

            if (event.aux[$-2].length)
            {
                import std.array : Appender;

                static Appender!(char[]) customEmoteSink;
                scope(exit) customEmoteSink.clear();

                immutable TerminalForeground highlight = plugin.state.settings.brightTerminal ?
                    Bright.highlight :
                    Dark.highlight;
                immutable TerminalForeground emoteFgBase = plugin.state.settings.brightTerminal ?
                    Bright.emote :
                    Dark.emote;

                customEmoteSink.highlightEmotesImpl(
                    event.aux[0],
                    event.aux[$-2],
                    highlight,
                    emoteFgBase,
                    cast(Flag!"colourful")plugin.printerSettings.colourfulEmotes,
                    plugin.state.settings);
                .put(sink, `: "`, customEmoteSink.data, '"');

                // Remove the custom emote definitions
                auxCopy[$-2] = string.init;
            }
            else
            {
                // No emotes embedded, probably not a home or no custom emotes for channel
                .put(sink, `: "`, event.aux[0], '"');
            }

            putQuotedTwitchMessage = true;
            auxCopy[0] = string.init;
        }
    }

    if (!putQuotedTwitchMessage)
    {
        if (event.target.nickname.length) putTarget();
        if (content.length) putContent();
    }

    // Base the range on the modified copy
    auto auxRange = auxCopy[].filter!(s => s.length);
    if (!auxRange.empty)
    {
        enum pattern = " (%-(%s%|) (%))";
        sink.applyANSI(bright ? Bright.aux : Dark.aux);

        static if ((__VERSION__ >= 2099L) && (__VERSION__ <= 2102L))
        {
            import std.array : array;
            // "Deprecation: scope variable `aux` assigned to non-scope parameter `_param_2` calling `formattedWrite"
            // Seemingly only between 2.099 and 2.102
            sink.formattedWrite(pattern, auxRange.array.dup);
        }
        else
        {
            sink.formattedWrite(pattern, auxRange);
        }
    }

    auto countRange = event.count[].filter!(n => !n.isNull);
    if (!countRange.empty)
    {
        enum pattern = " {%-(%s%|} {%)}";
        sink.applyANSI(bright ? Bright.count : Dark.count);
        sink.formattedWrite(pattern, countRange);
    }

    if (event.num > 0)
    {
        import lu.conv : toAlphaInto;

        sink.applyANSI(bright ? Bright.num : Dark.num);
        sink.put(" [#");
        event.num.toAlphaInto!(3, 3)(sink);
        sink.put(']');
    }

    if (event.errors.length)
    {
        immutable code = bright ? Bright.error : Dark.error;
        sink.applyANSI(code, ANSICodeType.foreground);
        .put(sink, " ! ", event.errors, " !");
    }

    sink.applyANSI(TerminalReset.all, ANSICodeType.reset);

    shouldBell = shouldBell ||
        ((event.type == IRCEvent.Type.QUERY) && bellOnMention) ||
        (event.errors.length && bellOnError);

    if (shouldBell) sink.put(plugin.transient.bell);
}


// withoutTypePrefix
/++
    Slices away any type prefixes from the string of a
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
auto withoutTypePrefix(const string typestring) pure @safe nothrow @nogc
{
    import std.algorithm.searching : startsWith;

    if (typestring.startsWith("RPL_") || typestring.startsWith("ERR_"))
    {
        return typestring[4..$];
    }
    else
    {
        version(TwitchSupport)
        {
            if (typestring.startsWith("TWITCH_"))
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
    [dialect.defs.IRCEvent|IRCEvent]'s `content` member.

    Wraps [highlightEmotesImpl].

    Params:
        event = [dialect.defs.IRCEvent|IRCEvent] whose content text to highlight.
        colourful = Whether or not emotes should be highlit in colours.
        settings = Current [kameloso.pods.CoreSettings|settings].

    Returns:
        A new string of the passed [dialect.defs.IRCEvent|IRCEvent]'s `content` member
        with any emotes highlighted, or said `content` member as-is if there weren't any.
 +/
version(Colours)
version(TwitchSupport)
auto highlightEmotes(
    const ref IRCEvent event,
    const Flag!"colourful" colourful,
    const CoreSettings settings)
{
    import kameloso.constants : DefaultColours;
    import kameloso.terminal.colours : applyANSI;
    import std.array : Appender;
    import std.exception : assumeUnique;
    import std.string : indexOf;

    alias Bright = EventPrintingBright;
    alias Dark = EventPrintingDark;

    if (!event.emotes.length) return event.content;

    static Appender!(char[]) sink;
    scope(exit) sink.clear();
    sink.reserve(event.content.length + 60);  // mostly +10

    immutable TerminalForeground highlight = settings.brightTerminal ?
        Bright.highlight :
        Dark.highlight;
    immutable isEmoteOnly = !colourful && (event.tags.indexOf("emote-only=1") != -1);

    with (IRCEvent.Type)
    switch (event.type)
    {
    case EMOTE:
    case SELFEMOTE:
        if (isEmoteOnly)
        {
            // Just highlight the whole line, don't worry about resetting to fgBase
            sink.applyANSI(highlight);
            sink.put(event.content);
            break;
        }

        // Emote but mixed text and emotes OR we're doing colourful emotes
        immutable TerminalForeground emoteFgBase = settings.brightTerminal ?
            Bright.emote :
            Dark.emote;

        sink.highlightEmotesImpl(
            event.content,
            event.emotes,
            highlight,
            emoteFgBase,
            colourful,
            settings);
        break;

    default:
        if (isEmoteOnly)
        {
            // / Emote only channel message, treat the same as an emote-only emote?
            goto case EMOTE;
        }

        // Normal content, normal text, normal emotes
        immutable TerminalForeground contentFgBase = settings.brightTerminal ?
            Bright.content :
            Dark.content;

        sink.highlightEmotesImpl(
            event.content,
            event.emotes,
            highlight,
            contentFgBase,
            colourful,
            settings);
        break;
    }

    return sink.data.assumeUnique();
}


// highlightEmotesImpl
/++
    Highlights Twitch emotes in the chat by tinting them a different colour,
    saving the results into a passed output range sink.

    Params:
        sink = Output range to put the results into.
        line = Content line whose containing emotes should be highlit.
        emotes = The list of emotes and their positions as divined from the
            IRCv3 tags of an event.
        pre = Terminal foreground tint to colour the emotes with.
        post = Terminal foreground tint to reset to after colouring an emote.
        colourful = Whether or not emotes should be highlit in colours.
        settings = Current [kameloso.pods.CoreSettings|settings].
 +/
version(Colours)
version(TwitchSupport)
void highlightEmotesImpl(Sink)
    (auto ref Sink sink,
    const string line,
    const string emotes,
    const TerminalForeground pre,
    const TerminalForeground post,
    const Flag!"colourful" colourful,
    const CoreSettings settings)
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
        immutable message = pattern.format(__FUNCTION__);
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
        if (highlights.data.length)
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
    auto sortedHighlights = highlights.data
        .dup
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
            getColourByHash(highlight.id, settings) :
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
            TerminalForeground.default_, No.colourful, darkSettings);
        assert((sink.data == "Moody the god \033[97mpownyFine\033[39m \033[97mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, darkSettings);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, darkSettings);
        assert((sink.data == "NOOOOOO \033[97mcamillsCry\033[39m " ~
            "\033[97mcamillsCry\033[39m \033[97mcamillsCry\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "822112:0-6,8-14,16-22";
        immutable line = "FortOne FortOne FortOne";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, darkSettings);
        assert((sink.data == "\033[97mFortOne\033[39m \033[97mFortOne\033[39m " ~
            "\033[97mFortOne\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "141844:17-24,26-33,35-42/141073:9-15";
        immutable line = "@mugs123 cohhWow cohhBoop cohhBoop cohhBoop";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, darkSettings);
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
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, brightSettings);
        assert((sink.data == highlitLine), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:32-36";
        immutable line = "@kiwiskool but you’re a sub too Kappa";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, brightSettings);
        assert((sink.data == "@kiwiskool but you’re a sub too \033[97mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, No.colourful, brightSettings);
        assert((sink.data == "高所恐怖症 \033[97mLUL\033[39m なにぬねの " ~
            "\033[97mLUL\033[39m \033[97m:)\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "425618:6-8,16-18/1:20-21";
        immutable line = "高所恐怖症 LUL なにぬねの LUL :)";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, brightSettings);
        assert((sink.data == "高所恐怖症 \033[38;5;171mLUL\033[39m なにぬねの " ~
            "\033[38;5;171mLUL\033[39m \033[35m:)\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "212612:14-22/75828:24-29";
        immutable line = "Moody the god pownyFine pownyL";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, brightSettings);
        assert((sink.data == "Moody the god \033[38;5;237mpownyFine\033[39m \033[38;5;159mpownyL\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "25:41-45";
        immutable line = "whoever plays nintendo switch whisper me Kappa";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, brightSettings);
        assert((sink.data == "whoever plays nintendo switch whisper me \033[38;5;49mKappa\033[39m"), sink.data);
    }
    {
        sink.clear();
        immutable emotes = "877671:8-17,19-28,30-39";
        immutable line = "NOOOOOO camillsCry camillsCry camillsCry";
        sink.highlightEmotesImpl(line, emotes, TerminalForeground.white,
            TerminalForeground.default_, Yes.colourful, brightSettings);
        assert((sink.data == "NOOOOOO \033[38;5;166mcamillsCry\033[39m " ~
            "\033[38;5;166mcamillsCry\033[39m \033[38;5;166mcamillsCry\033[39m"), sink.data);
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

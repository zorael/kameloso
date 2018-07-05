/++
 +  Various debugging functions, used to generate assertion statements for use
 +  in the source code `unittest` blocks.
 +/
module kameloso.debugging;

import kameloso.common : Client;
import kameloso.ircdefs : IRCBot, IRCEvent;

@safe:


// formatAssertStatementLines
/++
 +  Constructs assert statement lines for each changed field of a type.
 +
 +  This should not be used directly, instead use `formatEventAssertBlock`.
 +
 +  Example:
 +  ---
 +  IRCEvent event;
 +  Appender!string sink;
 +  sink.formatAssertStatementLines(event);
 +
 +  IRCBot bot;
 +  sink.formatAssertStatementLines(bot, "bot", 1);  // indented once
 +  ---
 +
 +  Params:
 +      sink = Output buffer to write the assert statements into.
 +      thing = Struct object to write the asserts for.
 +      prefix = String to preface the `thing`'s members' names with, to make
 +          them appear as fields of it; a prefix of "foo" for a member "name"
 +          makes the assert statements assert over "foo.name".
 +      indents = Order of indents to indent the text with. Used when
 +          `formatAssertStatementLines` recurses on structs.
 +/
private void formatAssertStatementLines(Sink, Thing)(auto ref Sink sink,
    Thing thing, const string prefix = string.init, const uint indents = 0)
{
    foreach (immutable i, member; thing.tupleof)
    {
        import std.traits : Unqual;

        alias T = Unqual!(typeof(member));
        enum memberstring = __traits(identifier, thing.tupleof[i]);

        // IRCEvent.raw is always visible in the parser.toIRCEvent command
        // and the time timestamp is not something we take into consideration
        static if ((memberstring == "raw") || (memberstring == "time"))
        {
            continue;
        }
        else static if (is(T == struct))
        {
            sink.formatAssertStatementLines(thing.tupleof[i], memberstring, indents);
        }
        else
        {
            import kameloso.string : tabs;
            import std.format : formattedWrite;

            static if (is(T == bool))
            {
                enum pattern = "%sassert(%s%s%s, %s%s.to!string);\n";
                sink.formattedWrite(pattern, indents.tabs,
                    !member ? "!" : string.init,
                    prefix.length ? prefix ~ '.' : string.init,
                    memberstring,
                    prefix.length ? prefix ~ '.' : string.init,
                    memberstring);
            }
            else
            {
                if (member != Thing.init.tupleof[i])
                {
                    import std.traits : isSomeString;

                    static if (isSomeString!T)
                    {
                        enum pattern = "%sassert((%s%s == \"%s\"), %s%s);\n";
                    }
                    /*else static if (is(T == enum))
                    {
                        // We can live with .to!string in unittest mode.
                        enum pattern = "%sassert((%s%s == %s), Enum!(typeof(%s%s)).toString(%5$s%6$s);\n";
                    }*/
                    else
                    {
                        enum pattern = "%sassert((%s%s == %s), %s%s.to!string);\n";
                    }

                    sink.formattedWrite(pattern, indents.tabs,
                        prefix.length ? prefix ~ '.' : string.init,
                        memberstring, member,
                        prefix.length ? prefix ~ '.' : string.init,
                        memberstring);
                }
            }
        }
    }
}

unittest
{
    import kameloso.irc : IRCParser;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(512);

    IRCBot bot;
    auto parser = IRCParser(bot);

    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");
    sink.formatAssertStatementLines(event, string.init, 2);

    assert(sink.data ==
`        assert((type == CHAN), type.to!string);
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
        assert((channel == "#flerrp"), channel);
        assert((content == "kameloso: 8ball"), content);
`, '\n' ~ sink.data);
}


// formatBotAssignment
/++
 +  Constructs statement lines for each changed field of an
 +  `kameloso.ircdefs.IRCBot`, including instantiating a fresh one.
 +
 +  Example:
 +  ---
 +  IRCCBot bot;
 +  Appender!string sink;
 +
 +  sink.formatBotAssignment(bot);
 +  ---
 +
 +  Params:
 +      sink = Output buffer to write to.
 +      bot = `kameloso.ircdefs.IRCBot` to simulate the assignment of.
 +/
void formatBotAssignment(Sink)(auto ref Sink sink, IRCBot bot)
{
    sink.put("IRCParser parser;\n");
    sink.put("with (parser.bot)\n");
    sink.put("{\n");
    sink.formatDelta(IRCBot.init, bot, 1);
    sink.put('}');

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

///
unittest
{
    import kameloso.ircdefs : IRCBot, IRCServer;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(128);

    IRCBot bot;
    with (bot)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
        server.address = "something.freenode.net";
        server.port = 0;
        server.daemon = IRCServer.Daemon.unreal;
        server.aModes = string.init;
    }

    sink.formatBotAssignment(bot);

    assert(sink.data ==
`IRCParser parser;
with (parser.bot)
{
    nickname = "NICKNAME";
    user = "UUUUUSER";
    server.address = "something.freenode.net";
    server.port = 0;
    server.daemon = IRCServer.Daemon.unreal;
    server.aModes = "";
}`, '\n' ~ sink.data);
}


// formatDelta
/++
 +  Constructs statement lines for each changed field (or the delta) between two
 +  instances of a struct.
 +
 +  Params:
 +      sink = Output buffer to write to.
 +      before = Original struct object.
 +      after = Changed struct object.
 +      indents = The number of tabs to indent the lines with.
 +      submember = The string name of a recursing symbol, if applicable.
 +/
void formatDelta(Sink, QualThing)(auto ref Sink sink, QualThing before, QualThing after,
    const uint indents = 0, const string submember = string.init)
if (is(QualThing == struct))
{
    import kameloso.string : tabs;
    import std.format : formattedWrite;
    import std.traits : isSomeFunction, isSomeString, isType, Unqual;

    alias Thing = Unqual!QualThing;

    immutable prefix = submember.length ? submember ~ '.' : string.init;

    foreach (immutable i, ref member; after.tupleof)
    {
        alias T = Unqual!(typeof(member));
        enum memberstring = __traits(identifier, before.tupleof[i]);

        static if (is(T == struct))
        {
            sink.formatDelta(before.tupleof[i], member, indents, prefix ~ memberstring);
        }
        else static if (!isType!member && !isSomeFunction!member)
        {
            if (after.tupleof[i] != before.tupleof[i])
            {
                static if (isSomeString!T)
                {
                    enum pattern = "%s%s%s = \"%s\";\n";
                }
                else static if (is(T == enum))
                {
                    import kameloso.string : nom;
                    import std.algorithm.searching : count;
                    import std.traits : fullyQualifiedName;

                    string typename = fullyQualifiedName!T;
                    while (typename.count('.') > 1) typename.nom('.');

                    immutable pattern = "%s%s%s = " ~ typename ~ ".%s;\n";
                }
                else
                {
                    enum pattern = "%s%s%s = %s;\n";
                }

                sink.formattedWrite(pattern, indents.tabs, prefix, memberstring, member);
            }
        }
        else
        {
            static assert(0, "Trying to format assignment delta of a %s, which can't be done".format(Thing.stringof));
        }
    }
}

///
unittest
{
    import kameloso.ircdefs : IRCBot, IRCServer;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(128);

    IRCBot bot;
    with (bot)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
        server.address = "something.freenode.net";
        server.port = 0;
        server.daemon = IRCServer.Daemon.unreal;
        server.aModes = string.init;
    }

    sink.formatDelta(IRCBot.init, bot);

    assert(sink.data ==
`nickname = "NICKNAME";
user = "UUUUUSER";
server.address = "something.freenode.net";
server.port = 0;
server.daemon = IRCServer.Daemon.unreal;
server.aModes = "";
`, '\n' ~ sink.data);

    struct Foo
    {
        string s;
        int i;
        bool b;
    }

    Foo f1;
    f1.s = "string";
    f1.i = 42;
    f1.b = true;

    Foo f2 = f1;
    f2.s = "yarn";
    f2.b = false;

    sink = typeof(sink).init;

    sink.formatDelta(f1, f2);
    assert(sink.data ==
`s = "yarn";
b = false;
`, '\n' ~ sink.data);
}


// formatEventAssertBlock
/++
 +  Constructs assert statement blocks for each changed field of an
 +  `kameloso.ircdefs.IRCEvent`.
 +
 +  Example:
 +  ---
 +  IRCEvent event;
 +  Appender!string sink;
 +  sink.formatEventAssertBlock(event);
 +  ---
 +
 +  Params:
 +      sink = Output buffer to write to.
 +      event = `kameloso.ircdefs.IRCEvent` to construct assert statements for.
 +/
void formatEventAssertBlock(Sink)(auto ref Sink sink, const IRCEvent event)
{
    import kameloso.string : tabs;
    import std.format : format, formattedWrite;

    immutable raw = event.tags.length ?
        "@%s %s".format(event.tags, event.raw) : event.raw;

    sink.put("{\n");
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n", 1.tabs, raw);
    sink.formattedWrite("%swith (IRCEvent.Type)\n", 1.tabs);
    sink.formattedWrite("%swith (IRCUser.Class)\n", 1.tabs);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatAssertStatementLines(event, string.init, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

unittest
{
    import kameloso.irc : IRCParser;
    import kameloso.ircdefs : IRCBot;
    import kameloso.string : tabs;
    import std.array : Appender;
    import std.format : formattedWrite;

    Appender!string sink;
    sink.reserve(512);

    IRCBot bot;
    auto parser = IRCParser(bot);

    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");

    // copy/paste the above
    sink.put("{\n");
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n", 1.tabs, event.raw);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatAssertStatementLines(event, string.init, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    assert(sink.data ==
`{
    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");
    with (event)
    {
        assert((type == CHAN), type.to!string);
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
        assert((channel == "#flerrp"), channel);
        assert((content == "kameloso: 8ball"), content);
    }
}`, '\n' ~ sink.data);
}


// generateAsserts
/++
 +  Reads raw server strings from `stdin`, parses them into
 +  `kameloso.ircdefs.IRCEvent`s and constructs assert blocks of their contents.
 +
 +  Example:
 +  ---
 +  Client client;
 +  client.generateAsserts();
 +  ---
 +
 +  Params:
 +      client = Reference to the current Client, with all its settings.
 +/
void generateAsserts(ref Client client) @system
{
    import kameloso.common : logger, printObjects;
    import kameloso.debugging : formatEventAssertBlock;
    import kameloso.ircdefs : IRCServer;
    import kameloso.string : Enum, has, nom, stripped;
    import std.conv : ConvException;
    import std.range : chunks, only;
    import std.stdio : stdout, readln, write, writeln, writefln;
    import std.traits : EnumMembers;
    import std.typecons : Flag, No, Yes;

    with (IRCServer)
    with (client)
    {
        import kameloso.irc : IRCParser;

        parser = IRCParser.init;

        logger.info("Available daemons:");
        writefln("%(%(%-14s%)\n%)", EnumMembers!(IRCServer.Daemon).only.chunks(3));
        writeln();

        write("Enter daemon (ircdseven): ");
        string slice = readln().stripped;

        immutable daemonstring = slice.has(" ") ? slice.nom(" ") : slice;
        immutable version_ = slice;

        try
        {
            immutable daemon = daemonstring.length ? Enum!Daemon.fromString(daemonstring) : Daemon.ircdseven;
            parser.setDaemon(daemon, version_);
        }
        catch (const ConvException e)
        {
            logger.error(e.msg);
            return;
        }

        write("Enter network (freenode): ");
        immutable network = readln().stripped;
        parser.bot.server.network = network.length ? network : "freenode";

        writeln();
        printObjects!(Yes.printAll)(parser.bot, parser.bot.server);
        writeln();

        parser.bot.updated = false;
        stdout.lockingTextWriter.formatBotAssignment(parser.bot);

        writeln();
        writeln("Paste raw event strings and hit Enter to generate an assert block.");
        writeln();

        string input;
        IRCBot old = parser.bot;

        while ((input = readln()) !is null)
        {
            import kameloso.irc : IRCParseException;
            import kameloso.string : beginsWithOneOf;

            if (*abort) return;

            scope(exit) version(Cygwin_) stdout.flush();

            string raw = input[0..$-1];  // mutable, slice away linebreak
            while (raw.beginsWithOneOf(" /"))
            {
                // Indented or commented; slice away and try again
                raw = raw[1..$];
            }

            if (!raw.length)
            {
                writeln("... empty line. (Ctrl+C to exit)");
                continue;
            }

            try
            {
                immutable event = parser.toIRCEvent(raw);
                writeln();

                stdout.lockingTextWriter.formatEventAssertBlock(event);
                writeln();

                if (parser.bot.updated)
                {
                    parser.bot.updated = false;

                    stdout.lockingTextWriter.formatDelta(old, parser.bot, 0, "bot");
                    writeln();

                    old = parser.bot;
                }
            }
            catch (const IRCParseException e)
            {
                logger.warning("IRC Parse Exception: ", e.msg);
                printObjects(e.event);
            }
            catch (const Exception e)
            {
                logger.warning("Exception: ", e.msg);
            }
        }
    }
}

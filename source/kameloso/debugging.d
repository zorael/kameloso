/++
 +  Various debugging functions, used to generate assertion statements for use
 +  in the source code `unittest` blocks.
 +/
module kameloso.debugging;

import kameloso.common : IRCBot;
import kameloso.irc.common : IRCClient;
import kameloso.irc.defs;

import std.typecons : Flag, No, Yes;

@safe:
debug:


// formatClientAssignment
/++
 +  Constructs statement lines for each changed field of an
 +  `kameloso.irc.common.IRCClient`, including instantiating a fresh one.
 +
 +  Example:
 +  ---
 +  IRCClient client;
 +  Appender!string sink;
 +
 +  sink.formatClientAssignment(client);
 +  ---
 +
 +  Params:
 +      sink = Output buffer to write to.
 +      client = `kameloso.irc.common.IRCClient` to simulate the assignment of.
 +/
void formatClientAssignment(Sink)(auto ref Sink sink, IRCClient client)
{
    sink.put("IRCParser parser;\n");
    sink.put("with (parser.client)\n");
    sink.put("{\n");
    sink.formatDelta(IRCClient.init, client, 1);
    sink.put('}');

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

///
unittest
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(128);

    IRCClient client;
    with (client)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
        server.address = "something.freenode.net";
        server.port = 0;
        server.daemon = IRCServer.Daemon.unreal;
        server.aModes = "eIbq";
    }

    sink.formatClientAssignment(client);

    assert(sink.data ==
`IRCParser parser;
with (parser.client)
{
    nickname = "NICKNAME";
    user = "UUUUUSER";
    server.address = "something.freenode.net";
    server.port = 0;
    server.daemon = IRCServer.Daemon.unreal;
    server.aModes = "eIbq";
}`, '\n' ~ sink.data);
}


// formatDelta
/++
 +  Constructs statement lines for each changed field (or the delta) between two
 +  instances of a struct.
 +
 +  Params:
 +      asserts = Whether or not to build assert statements or assign statements.
 +      sink = Output buffer to write to.
 +      before = Original struct object.
 +      after = Changed struct object.
 +      indents = The number of tabs to indent the lines with.
 +      submember = The string name of a recursing symbol, if applicable.
 +/
void formatDelta(Flag!"asserts" asserts = No.asserts, Sink, QualThing)
    (auto ref Sink sink, QualThing before, QualThing after,
    const uint indents = 0, const string submember = string.init)
if (is(QualThing == struct))
{
    import std.traits : Unqual;

    alias Thing = Unqual!QualThing;

    immutable prefix = submember.length ? submember ~ '.' : string.init;

    foreach (immutable i, ref member; after.tupleof)
    {
        import std.traits : isSomeFunction, isSomeString, isType;

        alias T = Unqual!(typeof(member));
        enum memberstring = __traits(identifier, before.tupleof[i]);

        static if ((memberstring == "raw") || (memberstring == "time"))
        {
            continue;
        }
        else static if (is(T == struct))
        {
            sink.formatDelta!asserts(before.tupleof[i], member, indents, prefix ~ memberstring);
        }
        else static if (!isType!member && !isSomeFunction!member && !__traits(isTemplate, member))
        {
            if (after.tupleof[i] != before.tupleof[i])
            {
                static if (isSomeString!T)
                {
                    static if (asserts)
                    {
                        enum pattern = "%sassert((%s%s == \"%s\"), %2$s%3$s);\n";
                    }
                    else
                    {
                        enum pattern = "%s%s%s = \"%s\";\n";
                    }
                }
                else static if (is(T == char))
                {
                    static if (asserts)
                    {
                        enum pattern = "%sassert((%s%s == '%s'), %2$s%3$s.to!string);\n";
                    }
                    else
                    {
                        enum pattern = "%s%s%s = '%s';\n";
                    }
                }
                else static if (is(T == enum))
                {
                    import kameloso.string : nom;
                    import std.algorithm.searching : count;
                    import std.traits : fullyQualifiedName;

                    string typename = fullyQualifiedName!T;
                    while (typename.count('.') > 1) typename.nom('.');

                    static if (asserts)
                    {
                        immutable pattern = "%sassert((%s%s == " ~ typename ~ ".%s), " ~
                            "Enum!(" ~ typename ~ ").toString(%2$s%3$s));\n";
                    }
                    else
                    {
                        immutable pattern = "%s%s%s = " ~ typename ~ ".%s;\n";
                    }
                }
                else static if (is(T == bool))
                {
                    static if (asserts)
                    {
                        immutable pattern = member ?
                            "%sassert(%s%s);\n" :
                            "%sassert(!%s%s);\n";
                    }
                    else
                    {
                        enum pattern = "%s%s%s = %s;\n";
                    }
                }
                else
                {
                    static if (asserts)
                    {
                        enum pattern = "%sassert((%s%s == %s), %2$s%3$s.to!string);\n";
                    }
                    else
                    {
                        enum pattern = "%s%s%s = %s;\n";
                    }
                }

                import kameloso.string : tabs;
                import std.format : formattedWrite;
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
    import kameloso.irc.parsing : IRCParser;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(128);

    IRCClient client;
    with (client)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
        server.address = "something.freenode.net";
        server.port = 0;
        server.daemon = IRCServer.Daemon.unreal;
        server.aModes = "eIbq";
    }

    sink.formatDelta(IRCClient.init, client);

    assert(sink.data ==
`nickname = "NICKNAME";
user = "UUUUUSER";
server.address = "something.freenode.net";
server.port = 0;
server.daemon = IRCServer.Daemon.unreal;
server.aModes = "eIbq";
`, '\n' ~ sink.data);

    sink = typeof(sink).init;

    sink.formatDelta!(Yes.asserts)(IRCClient.init, client);

assert(sink.data ==
`assert((nickname == "NICKNAME"), nickname);
assert((user == "UUUUUSER"), user);
assert((server.address == "something.freenode.net"), server.address);
assert((server.port == 0), server.port.to!string);
assert((server.daemon == IRCServer.Daemon.unreal), Enum!(IRCServer.Daemon).toString(server.daemon));
assert((server.aModes == "eIbq"), server.aModes);
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

    sink = typeof(sink).init;

    sink.formatDelta!(Yes.asserts)(f1, f2);
    assert(sink.data ==
`assert((s == "yarn"), s);
assert(!b);
`, '\n' ~ sink.data);

    sink = typeof(sink).init;
    auto parser = IRCParser(client);

    auto event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");
    event.sender.class_ = IRCUser.Class.special;
    sink.formatDelta!(Yes.asserts)(IRCEvent.init, event, 2);

    assert(sink.data ==
`        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
        assert((sender.nickname == "zorael"), sender.nickname);
        assert((sender.ident == "~NaN"), sender.ident);
        assert((sender.address == "2001:41d0:2:80b4::"), sender.address);
        assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
        assert((channel == "#flerrp"), channel);
        assert((content == "kameloso: 8ball"), content);
`, '\n' ~ sink.data);
}


// formatEventAssertBlock
/++
 +  Constructs assert statement blocks for each changed field of an
 +  `kameloso.irc.defs.IRCEvent`.
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
 +      event = `kameloso.irc.defs.IRCEvent` to construct assert statements for.
 +/
void formatEventAssertBlock(Sink)(auto ref Sink sink, const IRCEvent event)
{
    import kameloso.string : tabs;
    import std.format : format, formattedWrite;

    immutable raw = event.tags.length ?
        "@%s %s".format(event.tags, event.raw) : event.raw;

    sink.put("{\n");
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n", 1.tabs, raw);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatDelta!(Yes.asserts)(IRCEvent.init, event, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

unittest
{
    import kameloso.irc.parsing : IRCParser;
    import kameloso.string : tabs;
    import std.array : Appender;
    import std.format : formattedWrite;

    Appender!string sink;
    sink.reserve(1024);

    IRCClient client;
    auto parser = IRCParser(client);

    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");

    // copy/paste the above
    sink.put("{\n");
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n", 1.tabs, event.raw);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatDelta!(Yes.asserts)(IRCEvent.init, event, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    assert(sink.data ==
`{
    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");
    with (event)
    {
        assert((type == IRCEvent.Type.CHAN), Enum!(IRCEvent.Type).toString(type));
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
 +  `kameloso.irc.defs.IRCEvent`s and constructs assert blocks of their contents.
 +
 +  Example:
 +  ---
 +  IRCBot bot;
 +  bot.generateAsserts();
 +  ---
 +
 +  Params:
 +      bot = Reference to the current `kameloso.common.IRCBot`, with all its settings.
 +/
void generateAsserts(ref IRCBot bot) @system
{
    import kameloso.common : logger;
    import kameloso.irc.defs : IRCServer;
    import kameloso.printing : printObjects;
    import kameloso.string : contains, nom, stripped;
    import std.conv : ConvException;
    import std.range : chunks, only;
    import std.stdio : stdout, readln, write, writeln, writefln;
    import std.traits : EnumMembers;
    import std.typecons : No, Yes;

    with (IRCServer)
    with (bot)
    {
        import kameloso.irc.parsing : IRCParser;  // Must be here or shadows IRCBot : IRCParser

        parser = IRCParser.init;

        logger.info("Available daemons:");
        writefln("%(%(%-14s%)\n%)", EnumMembers!(IRCServer.Daemon).only.chunks(3));
        writeln();

        write("Enter daemon (ircdseven): ");
        string slice = readln().stripped;

        immutable daemonstring = slice.contains(' ') ? slice.nom(' ') : slice;
        immutable version_ = slice;

        try
        {
            import kameloso.conv : Enum;
            import kameloso.irc.common : typenumsOf;

            immutable daemon = daemonstring.length ? Enum!Daemon.fromString(daemonstring) : Daemon.ircdseven;
            parser.typenums = typenumsOf(daemon);
            parser.client.server.daemon = daemon;
            parser.client.server.daemonstring = version_;
            parser.client.updated = true;
        }
        catch (ConvException e)
        {
            logger.error("Conversion exception caught when parsing daemon: ", e.msg);
            version(PrintStacktraces) logger.trace(e.info);
            return;
        }

        write("Enter network (freenode): ");
        immutable network = readln().stripped;
        parser.client.server.network = network.length ? network : "freenode";

        // Provide Freenode defaults here, now that they're no longer in IRCServer.init
        with (parser.client.server)
        {
            aModes = "eIbq";
            bModes = "k";
            cModes = "flj";
            dModes = "CFLMPQScgimnprstz";
            prefixes = "ov";
            prefixchars = [ 'o' : '@', 'v' : '+' ];
        }

        write("Enter server address (irc.freenode.net): ");
        parser.client.server.address = readln().stripped;
        if (!parser.client.server.address.length) parser.client.server.address = "irc.freenode.net";

        writeln();
        printObjects!(Yes.printAll)(parser.client, parser.client.server);
        writeln();

        parser.client.updated = false;
        stdout.lockingTextWriter.formatClientAssignment(parser.client);
        writeln();
        writeln("parser.typenums = typenumsOf(parser.client.server.daemon);");

        writeln();
        writeln("// Paste raw event strings and hit Enter to generate an assert block. " ~
            "Ctrl+C twice to exit.");
        writeln();

        string input;
        IRCClient old = parser.client;

        while ((input = readln()) !is null)
        {
            import kameloso.irc.common : IRCParseException;
            import kameloso.string : beginsWithOneOf;

            if (*abort) return;

            version(FlushStdout) scope(exit) stdout.flush();

            string raw = input[0..$-1];  // mutable, slice away linebreak
            while (raw.beginsWithOneOf(" /"))
            {
                // Indented or commented; slice away and try again
                raw = raw[1..$];
            }

            import core.thread : Thread;
            import core.time : msecs;

            Thread.sleep(75.msecs);

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

                if (parser.client.updated)
                {
                    parser.client.updated = false;

                    writeln("/*");
                    /+writeln("with (parser.client)");
                    writeln("{");+/
                    stdout.lockingTextWriter.formatDelta!(No.asserts)(old, parser.client, 0);
                    /+writeln("}");+/
                    writeln("*/");
                    writeln();

                    writeln("with (parser.client)");
                    writeln("{");

                    stdout.lockingTextWriter.formatDelta!(Yes.asserts)(old, parser.client, 1);
                    writeln("}\n");

                    old = parser.client;
                }
            }
            catch (IRCParseException e)
            {
                import kameloso.printing : printObject;
                logger.warningf("IRC Parse Exception at %s:%d: %s", e.file, e.line, e.msg);
                printObject(e.event);
                version(PrintStacktraces) logger.trace(e.info);
            }
            catch (Exception e)
            {
                logger.warningf("Exception at %s:%d: %s", e.file, e.line, e.msg);
                version(PrintStacktraces) logger.trace(e.toString);
            }
        }
    }
}

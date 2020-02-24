/++
 +  Various debugging functions, used to generate assertion statements for use
 +  in the source code `unittest` blocks in upstream `dialect`.
 +
 +  Raw IRC strings can be gotten from toggling the `printRaw` feature of the Admin
 +  plugin, alternatively via its `printAsserts`. Its generated asserts are not
 +  necessarily possible to copy/paste into `dialect` however, because of how we make
 +  information about users persistent across events with the Persistence service.
 +
 +  For this, the `--asserts` flag is used.
 +
 +  Example:
 +
 +  `$ kameloso --asserts`
 +  ---
 + [...]
 +
// Paste raw event strings and hit Enter to generate an assert block. Ctrl+C twice to exit.

@badge-info=subscriber/15;badges=subscriber/12;color=;display-name=tayk47_mom;emotes=;flags=;id=d6729804-2bf3-495d-80ce-a2fe8ed00a26;login=tayk47_mom;mod=0;msg-id=submysterygift;msg-pa
ram-mass-gift-count=1;msg-param-origin-id=49\s9d\s3e\s68\sca\s26\se9\s2a\s6e\s44\sd4\s60\s9b\s3d\saa\sb9\s4c\sad\s43\s5c;msg-param-sender-count=4;msg-param-sub-plan=1000;room-id=710929
38;subscriber=1;system-msg=tayk47_mom\sis\sgifting\s1\sTier\s1\sSubs\sto\sxQcOW's\scommunity!\sThey've\sgifted\sa\stotal\sof\s4\sin\sthe\schannel!;tmi-sent-ts=1569013433362;user-id=224
578549;user-type= :tmi.twitch.tv USERNOTICE #xqcow

{
    immutable event = parser.toIRCEvent("@badge-info=subscriber/15;badges=subscriber/12;color=;display-name=tayk47_mom;emotes=;flags=;id=d6729804-2bf3-495d-80ce-a2fe8ed00a26;login=tayk
47_mom;mod=0;msg-id=submysterygift;msg-param-mass-gift-count=1;msg-param-origin-id=49\\s9d\\s3e\\s68\\sca\\s26\\se9\\s2a\\s6e\\s44\\sd4\\s60\\s9b\\s3d\\saa\\sb9\\s4c\\sad\\s43\\s5c;msg
-param-sender-count=4;msg-param-sub-plan=1000;room-id=71092938;subscriber=1;system-msg=tayk47_mom\\sis\\sgifting\\s1\\sTier\\s1\\sSubs\\sto\\sxQcOW's\\scommunity!\\sThey've\\sgifted\\s
a\\stotal\\sof\\s4\\sin\\sthe\\schannel!;tmi-sent-ts=1569013433362;user-id=224578549;user-type= :tmi.twitch.tv USERNOTICE #xqcow");
    with (event)
    {
        assert((type == IRCEvent.Type.TWITCH_BULKGIFT), Enum!(IRCEvent.Type).toString(type));
        assert((sender.nickname == "tayk47_mom"), sender.nickname);
        assert((sender.displayName == "tayk47_mom"), sender.displayName);
        assert((sender.account == "tayk47_mom"), sender.account);
        assert((sender.badges == "subscriber/12"), sender.badges);
        assert((channel == "#xqcow"), channel);
        assert((content == "tayk47_mom is gifting 1 Tier 1 Subs to xQcOW's community! They've gifted a total of 4 in the channel!"), content);
        assert((aux == "1000"), aux);
        assert((tags == "badge-info=subscriber/15;badges=subscriber/12;color=;display-name=tayk47_mom;emotes=;flags=;id=d6729804-2bf3-495d-80ce-a2fe8ed00a26;login=tayk47_mom;mod=0;msg-
id=submysterygift;msg-param-mass-gift-count=1;msg-param-origin-id=49\\s9d\\s3e\\s68\\sca\\s26\\se9\\s2a\\s6e\\s44\\sd4\\s60\\s9b\\s3d\\saa\\sb9\\s4c\\sad\\s43\\s5c;msg-param-sender-cou
nt=4;msg-param-sub-plan=1000;room-id=71092938;subscriber=1;system-msg=tayk47_mom\\sis\\sgifting\\s1\\sTier\\s1\\sSubs\\sto\\sxQcOW's\\scommunity!\\sThey've\\sgifted\\sa\\stotal\\sof\\s
4\\sin\\sthe\\schannel!;tmi-sent-ts=1569013433362;user-id=224578549;user-type="), tags);
        assert((count == 1), count.to!string);
        assert((altcount == 4), altcount.to!string);
        assert((id == "d6729804-2bf3-495d-80ce-a2fe8ed00a26"), id);
    }
}
 +  ---
 +
 +  Generated with the `--asserts` flag, these can be directly copy/pasted into
 +  `dialect`. They only carry state from the events pasted before it, but the
 +  changes made are also made copy/pastable.
 +
 +  Example:
 +
 +  `$ kameloso --asserts`
 +  ---
 + [...]
 +
// Paste raw event strings and hit Enter to generate an assert block. Ctrl+C twice to exit.

@badge-info=;badges=;color=#5F9EA0;display-name=Zorael;emote-sets=0,185411,771823,1511983;user-id=22216721;user-type= :tmi.twitch.tv GLOBALUSERSTATE

{
        immutable event = parser.toIRCEvent("@badge-info=;badges=;color=#5F9EA0;display-name=Zorael;emote-sets=0,185411,771823,1511983;user-id=22216721;user-type= :tmi.twitch.tv GLOBALUSERSTATE");
        with (event)
        {
            assert((type == IRCEvent.Type.GLOBALUSERSTATE), Enum!(IRCEvent.Type).toString(type));
            assert((sender.address == "tmi.twitch.tv"), sender.address);
            assert((sender.class_ == IRCUser.Class.special), Enum!(IRCUser.Class).toString(sender.class_));
            assert((target.nickname == "zorael"), target.nickname);
            assert((target.displayName == "Zorael"), target.displayName);
            assert((target.class_ == IRCUser.Class.admin), Enum!(IRCUser.Class).toString(target.class_));
            assert((target.badges == "*"), target.badges);
            assert((target.colour == "5F9EA0"), target.colour);
            assert((tags == "badge-info=;badges=;color=#5F9EA0;display-name=Zorael;emote-sets=0,185411,771823,1511983;user-id=22216721;user-type="), tags);
        }
    }

    with (parser.client)
    {
        assert((displayName == "Zorael"), displayName);
    }
}
 +  ---
 +
 +  The `with (parser.client)` segment, inlined with the rest of the test, will
 +  update the parser's `dialect.defs.IRCClient` with information gleamed from
 +  this one, giving it new context to events pasted afterwards.
 +
 +  This makes it easy to generate tests that precisely reflect what kind of
 +  `dialect.defs.IRCEvent`s given strings are parsed into, enabling us to
 +  detect any unwanted side-effects to changes we make.
 +/
module kameloso.debugging;

import kameloso.common : Kameloso;
import dialect.defs;
import lu.deltastrings : formatDeltaInto;

import std.range.primitives : isOutputRange;
import std.typecons : Flag, No, Yes;

version(AssertsGeneration):

@safe:


// formatClientAssignment
/++
 +  Constructs statement lines for each changed field of an
 +  `dialect.defs.IRCClient`, including instantiating a fresh one.
 +
 +  Example:
 +  ---
 +  IRCClient client;
 +  IRCServer server;
 +  Appender!string sink;
 +
 +  sink.formatClientAssignment(client, server);
 +  ---
 +
 +  Params:
 +      sink = Output buffer to write to.
 +      client = `dialect.defs.IRCClient` to simulate the assignment of.
 +      server = `dialect.defs.IRCServer` to simulate the assignment of.
 +/
void formatClientAssignment(Sink)(auto ref Sink sink, const IRCClient client, const IRCServer server)
if (isOutputRange!(Sink, char[]))
{
    static if (!__traits(hasMember, Sink, "put")) import std.range.primitives : put;

    sink.put("IRCParser parser;\n\n");
    sink.put("with (parser)\n");
    sink.put("{\n");
    sink.formatDeltaInto(IRCClient.init, client, 1, "client");
    sink.formatDeltaInto(IRCServer.init, server, 1, "server");
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
    IRCServer server;

    with (client)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
        server.address = "something.freenode.net";
        server.port = 6667;
        server.daemon = IRCServer.Daemon.unreal;
        server.aModes = "eIbq";
    }

    sink.formatClientAssignment(client, server);

    assert(sink.data ==
`IRCParser parser;

with (parser)
{
    client.nickname = "NICKNAME";
    client.user = "UUUUUSER";
    server.address = "something.freenode.net";
    server.port = 6667;
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
if (isOutputRange!(Sink, char[]) && is(QualThing == struct))
{
    immutable prefix = submember.length ? submember ~ '.' : string.init;

    foreach (immutable i, ref member; after.tupleof)
    {
        import lu.uda : Hidden;
        import std.functional : unaryFun;
        import std.traits : Unqual, hasUDA, isSomeFunction, isSomeString, isType;

        alias Thing = Unqual!QualThing;
        alias T = Unqual!(typeof(member));
        enum memberstring = __traits(identifier, before.tupleof[i]);

        static if (hasUDA!(Thing.tupleof[i], Hidden))
        {
            // Member is annotated as Hidden; skip
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
                    import lu.string : nom;
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

                import lu.string : tabs;
                import std.format : formattedWrite;

                static if (isSomeString!T)
                {
                    import std.array : replace;

                    immutable escaped = member
                        .replace('\\', `\\`)
                        .replace('"', `\"`);

                    sink.formattedWrite(pattern, indents.tabs, prefix, memberstring, escaped);
                }
                else
                {
                    sink.formattedWrite(pattern, indents.tabs, prefix, memberstring, member);
                }
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
    import dialect.parsing : IRCParser;
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(128);

    IRCClient client;
    IRCServer server;

    with (client)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
        server.address = "something.freenode.net";
        server.port = 6667;
        server.daemon = IRCServer.Daemon.unreal;
        server.aModes = "eIbq";
    }

    sink.formatDelta(IRCClient.init, client, 0, "client");
    sink.formatDelta(IRCServer.init, server, 0, "server");

    assert(sink.data ==
`client.nickname = "NICKNAME";
client.user = "UUUUUSER";
server.address = "something.freenode.net";
server.port = 6667;
server.daemon = IRCServer.Daemon.unreal;
server.aModes = "eIbq";
`, '\n' ~ sink.data);


    sink = typeof(sink).init;

    sink.formatDelta!(Yes.asserts)(IRCClient.init, client, 0, "client");
    sink.formatDelta!(Yes.asserts)(IRCServer.init, server, 0, "server");

assert(sink.data ==
`assert((client.nickname == "NICKNAME"), client.nickname);
assert((client.user == "UUUUUSER"), client.user);
assert((server.address == "something.freenode.net"), server.address);
assert((server.port == 6667), server.port.to!string);
assert((server.daemon == IRCServer.Daemon.unreal), Enum!(IRCServer.Daemon).toString(server.daemon));
assert((server.aModes == "eIbq"), server.aModes);
`, '\n' ~ sink.data);


    struct Foo
    {
        string s;
        int i;
        bool b;
        char c;
    }

    Foo f1;
    f1.s = "string";
    f1.i = 42;
    f1.b = true;
    f1.c = '$';

    Foo f2 = f1;
    f2.s = "yarn";
    f2.b = false;
    f2.c = '#';

    sink = typeof(sink).init;

    sink.formatDelta(f1, f2);
    assert(sink.data ==
`s = "yarn";
b = false;
c = '#';
`, '\n' ~ sink.data);

    sink = typeof(sink).init;

    sink.formatDelta!(Yes.asserts)(f1, f2);
    assert(sink.data ==
`assert((s == "yarn"), s);
assert(!b);
assert((c == '#'), c.to!string);
`, '\n' ~ sink.data);

    sink = typeof(sink).init;
    auto parser = IRCParser(client, server);

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
 +  `dialect.defs.IRCEvent`.
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
 +      event = `dialect.defs.IRCEvent` to construct assert statements for.
 +/
void formatEventAssertBlock(Sink)(auto ref Sink sink, const IRCEvent event)
if (isOutputRange!(Sink, char[]))
{
    import lu.string : tabs;
    import std.array : replace;
    import std.format : format, formattedWrite;

    static if (!__traits(hasMember, Sink, "put")) import std.range.primitives : put;

    immutable raw = event.tags.length ?
        "@%s %s".format(event.tags, event.raw) : event.raw;

    immutable escaped = raw
        .replace('\\', `\\`)
        .replace('"', `\"`);

    sink.put("{\n");
    if (escaped != raw) sink.formattedWrite("%s// %s\n", 1.tabs, raw);
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n", 1.tabs, escaped);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatDeltaInto!(Yes.asserts)(IRCEvent.init, event, 2);
    sink.formattedWrite("%s}\n", 1.tabs);
    sink.put("}");

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

unittest
{
    import dialect.parsing : IRCParser;
    import lu.string : tabs;
    import std.array : Appender;
    import std.format : formattedWrite;

    Appender!string sink;
    sink.reserve(1024);

    IRCClient client;
    IRCServer server;
    auto parser = IRCParser(client, server);

    immutable event = parser.toIRCEvent(":zorael!~NaN@2001:41d0:2:80b4:: PRIVMSG #flerrp :kameloso: 8ball");

    // copy/paste the above
    sink.put("{\n");
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n", 1.tabs, event.raw);
    sink.formattedWrite("%swith (event)\n", 1.tabs);
    sink.formattedWrite("%s{\n", 1.tabs);
    sink.formatDeltaInto!(Yes.asserts)(IRCEvent.init, event, 2);
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
 +  `dialect.defs.IRCEvent`s and constructs assert blocks of their contents.
 +
 +  Example:
 +  ---
 +  Kameloso instance;
 +  instance.generateAsserts();
 +  ---
 +
 +  Params:
 +      instance = Reference to the current `kameloso.common.Kameloso`, with all its settings.
 +/
void generateAsserts(ref Kameloso instance) @system
{
    import kameloso.common : logger;
    import kameloso.printing : printObjects;
    import dialect.defs : IRCServer;
    import lu.string : contains, nom, stripped;
    import std.conv : ConvException;
    import std.range : chunks, only;
    import std.stdio : stdout, readln, write, writeln, writefln;
    import std.traits : EnumMembers;
    import std.typecons : No, Yes;

    with (IRCServer)
    with (instance)
    {
        import dialect.parsing : IRCParser;  // Must be here or shadows Kameloso : IRCParser

        parser.initPostprocessors();  // Normally done in IRCParser(IRCClient) constructor

        logger.info("Available daemons:");
        writefln("%(%(%-14s%)\n%)", EnumMembers!(IRCServer.Daemon).only.chunks(3));
        writeln();

        write("Enter daemon (ircdseven): ");
        string slice = readln().stripped;

        immutable daemonstring = slice.contains(' ') ? slice.nom(' ') : slice;
        immutable version_ = slice;

        try
        {
            import dialect.common : typenumsOf;
            import lu.conv : Enum;

            immutable daemon = daemonstring.length ? Enum!Daemon.fromString(daemonstring) : Daemon.ircdseven;
            parser.typenums = typenumsOf(daemon);
            parser.server.daemon = daemon;
            parser.server.daemonstring = version_;
            parser.clientUpdated = true;
        }
        catch (ConvException e)
        {
            logger.error("Conversion exception caught when parsing daemon: ", e.msg);
            version(PrintStacktraces) logger.trace(e.info);
            return;
        }

        write("Enter network (freenode): ");
        immutable network = readln().stripped;
        parser.server.network = network.length ? network : "freenode";

        // Provide Freenode defaults here, now that they're no longer in IRCServer.init
        with (parser.server)
        {
            aModes = "eIbq";
            bModes = "k";
            cModes = "flj";
            dModes = "CFLMPQScgimnprstz";
            prefixes = "ov";
            prefixchars = [ 'o' : '@', 'v' : '+' ];
        }

        write("Enter server address (irc.freenode.net): ");
        parser.server.address = readln().stripped;
        if (!parser.server.address.length) parser.server.address = "irc.freenode.net";

        writeln();
        printObjects!(Yes.printAll)(parser.client, parser.server);
        writeln();

        parser.clientUpdated = false;
        stdout.lockingTextWriter.formatClientAssignment(parser.client, parser.server);
        writeln();
        writeln("parser.typenums = typenumsOf(parser.server.daemon);");

        writeln();
        writeln("// Paste raw event strings and hit Enter to generate an assert block. " ~
            "Ctrl+C twice to exit.");
        writeln();

        string input;
        IRCClient oldClient = parser.client;
        IRCServer oldServer = parser.server;

        while ((input = readln()) !is null)
        {
            import dialect.common : IRCParseException;
            import lu.string : beginsWithOneOf;

            if (*abort) return;

            scope(exit)
            {
                import kameloso.common : settings;
                if (settings.flush) stdout.flush();
            }

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
                IRCEvent event = parser.toIRCEvent(raw);

                writeln();

                stdout.lockingTextWriter.formatEventAssertBlock(event);
                writeln();

                if (parser.clientUpdated || parser.serverUpdated)
                {
                    parser.clientUpdated = false;
                    parser.serverUpdated = false;

                    writeln("with (parser)");
                    writeln("{");
                    stdout.lockingTextWriter.formatDeltaInto!(Yes.asserts)(oldClient, parser.client, 1, "client");
                    stdout.lockingTextWriter.formatDeltaInto!(Yes.asserts)(oldServer, parser.server, 1, "server");
                    writeln("}\n");

                    oldClient = parser.client;
                    oldServer = parser.server;
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

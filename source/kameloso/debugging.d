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
 +  ------------
 +  IRCEvent event;
 +  Appender!string sink;
 +  sink.formatAssertStatementLines(event);
 +
 +  IRCBot bot;
 +  sink.formatAssertStatementLines(bot, "bot", 1);  // indented once
 +  ------------
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
    Thing thing, const string prefix = string.init, uint indents = 0)
{
    foreach (immutable i, value; thing.tupleof)
    {
        import std.traits : Unqual;

        alias T = Unqual!(typeof(value));
        enum memberstring = __traits(identifier, thing.tupleof[i]);

        // IRCEvent.target.special is at present never true
        if ((prefix == "target") && (memberstring == "special")) continue;

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
                    !value ? "!" : string.init,
                    prefix.length ? prefix ~ '.' : string.init,
                    memberstring,
                    prefix.length ? prefix ~ '.' : string.init,
                    memberstring);
            }
            else
            {
                if (value != Thing.init.tupleof[i])
                {
                    import std.traits : isSomeString;

                    static if (isSomeString!T)
                    {
                        enum pattern = "%sassert((%s%s == \"%s\"), %s%s);\n";
                    }
                    else
                    {
                        enum pattern = "%sassert((%s%s == %s), %s%s.to!string);\n";
                    }

                    sink.formattedWrite(pattern, indents.tabs,
                        prefix.length ? prefix ~ '.' : string.init,
                        memberstring, value,
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
 +  ------------
 +  IRCCBot bot;
 +  Appender!string sink;
 +
 +  sink.formatBotAssignment(bot);
 +  ------------
 +
 +  Params:
 +      sink = Output buffer to write to.
 +      bot = `kameloso.ircdefs.IRCBot` to simulate the assignment of.
 +/
void formatBotAssignment(Sink)(auto ref Sink sink, const IRCBot bot)
{
    sink.put("IRCParser parser;\n");
    sink.put("with (parser.bot)\n");
    sink.put("{\n");

    foreach (immutable i, value; bot.tupleof)
    {
        import kameloso.string : tabs;
        import std.format : formattedWrite;
        import std.traits : isSomeString;

        alias T = typeof(value);
        enum memberstring = __traits(identifier, bot.tupleof[i]);

        static if (is(T == struct) || is(T == class))
        {
            // Can't recurse for now, future improvement
            continue;
        }
        else
        {
            if (value != IRCBot.init.tupleof[i])
            {
                static if (isSomeString!T)
                {
                    enum pattern = "%s%s = \"%s\";\n";
                }
                else
                {
                    enum pattern = "%s%s = %s;\n";
                }

                sink.formattedWrite(pattern, 1.tabs, memberstring, value);
            }
        }

    }

    sink.put("}");

    static if (!__traits(hasMember, Sink, "data"))
    {
        sink.put('\n');
    }
}

unittest
{
    import std.array : Appender;

    Appender!string sink;
    sink.reserve(128);

    IRCBot bot;
    with (bot)
    {
        nickname = "NICKNAME";
        user = "UUUUUSER";
    }

    sink.formatBotAssignment(bot);

    assert(sink.data ==
`IRCParser parser;
with (parser.bot)
{
    nickname = "NICKNAME";
    user = "UUUUUSER";
}`, '\n' ~ sink.data);
}


// formatEventAssertBlock
/++
 +  Constructs assert statement blocks for each changed field of an
 +  `kameloso.ircdefs.IRCEvent`.
 +
 +  Example:
 +  ------------
 +  IRCEvent event;
 +  Appender!string sink;
 +  sink.formatEventAssertBlock(event);
 +  ------------
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
 +  Reads raw server strings from `stdin`, parses them to
 +  `kameloso.ircdefs.IRCEvent`s and constructs assert blocks of their contents.
 +
 +  We can't use an `std.array.Appender` or dmd will hit a stack overflow,
 +  error -11.
 +
 +  Example:
 +  ------------
 +  Client client;
 +  client.generateAsserts();
 +  ------------
 +
 +  Params:
 +      client = Reference to the current Client, with all its settings.
 +/
void generateAsserts(ref Client client) @system
{
    import kameloso.common : printObject;
    import kameloso.debugging : formatEventAssertBlock;
    //import std.array : Appender;
    import std.stdio : stdout, readln, writeln;

    //Appender!(char[]) sink;
    //sink.reserve(768);

    with (client)
    {
        printObject(parser.bot);
        writeln("Paste raw event strings and hit enter to generate an assert block.");
        writeln();

        string input;

        while ((input = readln()) !is null)
        {
            import std.regex : matchFirst, regex;
            if (*abort) return;

            auto hits = input[0..$-1].matchFirst("^[ /]*(.+)".regex);
            if (!hits[1].length) break;

            immutable event = parser.toIRCEvent(hits[1]);
            //sink.formatEventAssertBlock(event);
            writeln();
            stdout.lockingTextWriter.formatEventAssertBlock(event);
            version(Cygwin_) stdout.flush();
            //writeln(sink.data);
            //sink.clear();
        }
    }
}

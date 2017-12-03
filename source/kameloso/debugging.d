module kameloso.debugging;

import kameloso.irc : IRCBot, IRCEvent;
import std.stdio;


// formatAssertStatementLines
/++
 +  Constructs assert statement lines for each changed field of a type.
 +
 +  This belongs elsewhere but will stay here for now.
 +/
void formatAssertStatementLines(Sink, Thing)(auto ref Sink sink, Thing thing,
    const string prefix = string.init, uint depth = 0)
{
    foreach (immutable i, value; thing.tupleof)
    {
        import std.traits : Unqual;

        alias T = Unqual!(typeof(value));
        enum memberstring = __traits(identifier, thing.tupleof[i]);

        static if ((memberstring == "raw") || (memberstring == "time"))
        {
            continue;
        }
        else static if (is(T == struct))
        {
            sink.formatAssertStatementLines(thing.tupleof[i], memberstring, depth);
        }
        else
        {
            import kameloso.string : tabs;
            import std.format : formattedWrite;

            static if (is(T == bool))
            {
                enum pattern = "%sassert(%s%s%s, %s%s.to!string);\n";
                sink.formattedWrite(pattern,
                        depth.tabs,
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

                    sink.formattedWrite(pattern,
                        depth.tabs,
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
        assert(!sender.special, sender.special.to!string);
        assert((channel == "#flerrp"), channel);
        assert(!target.special, target.special.to!string);
        assert((content == "kameloso: 8ball"), content);
`, '\n' ~ sink.data);
}


// formatAssertStatementLines
/++
 +  Constructs statement lines for each changed field of an `IRCBot`, including
 +  instantiating a fresh one.
 +
 +  This belongs elsewhere but will stay here for now.
 +/
void formatBot(Sink)(auto ref Sink sink, const IRCBot bot)
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

    sink.formatBot(bot);

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
 +  Constructs assert statement blocks for each changed field of an `IRCEvent`.
 +
 +  This belongs elsewhere but will stay here for now.
 +/
public void formatEventAssertBlock(Sink)(auto ref Sink sink, const IRCEvent event)
{
    import kameloso.string : tabs;
    import std.format : format, formattedWrite;

    immutable raw = event.tags.length ?
        "@%s %s".format(event.tags, event.raw) : event.raw;

    sink.put("{\n");
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n",
        1.tabs, raw);
    sink.formattedWrite("%swith (IRCEvent.Type)\n", 1.tabs);
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

version(none)  // FIXME
unittest
{
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
    sink.formattedWrite("%simmutable event = parser.toIRCEvent(\"%s\");\n",
        1.tabs, event.raw);
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

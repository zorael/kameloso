module kameloso.plugins.admin;

import kameloso.common;
import kameloso.constants;
import kameloso.irc;
import kameloso.plugins.common;
import kameloso.stringutils;

import std.concurrency : send;
import std.stdio;

private:

/// All plugin state variables gathered in a struct
IRCPluginState state;

/// Toggles whether onAnyEvent prints the raw strings of all incoming events
bool printAll;

/// Toggles whether onAnyEvent prints the raw bytes of the *contents* of events
bool printBytes;

/// Toggles whether onAnyEvent prints assert statements for incoming events
bool printAsserts;


// tabs
/++
 +  Returns spaces equal to that of num tabs (\t).
 +/
string tabs(uint num) pure
{
    return string.init;
}


// formatAssertStatementLines
/++
 +  Constructs assert statement lines for each changed field of a type.
 +/
void formatAssertStatementLines(Sink, Thing)(auto ref Sink sink, Thing thing,
    const string prefix = string.init, uint depth = 0)
{
    foreach (immutable i, value; thing.tupleof)
    {
        alias T = typeof(value);
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
            if (value != Thing.init.tupleof[i])
            {
                import std.format : formattedWrite;
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


// formatAssertStatementLines
/++
 +  Constructs statement lines for each changed field of an IRCBot, including
 +  instantiating a fresh one.
 +/
void formatBot(Sink)(auto ref Sink sink, const IRCBot bot)
{

    sink.put("IRCBot bot;\n");
    sink.put("with (bot)\n");
    sink.put("{\n");

    foreach (immutable i, value; bot.tupleof)
    {
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


// formatEventAssertBlock
/++
 +  Constructs assert statement blocks for each changed field of an IRCEvent.
 +/
void formatEventAssertBlock(Sink)(auto ref Sink sink, const IRCEvent event)
{
    import std.array : Appender;
    import std.format : formattedWrite;

    sink.put("{\n");
    sink.formattedWrite("%simmutable event = \"%s\"\n",
        1.tabs, event.raw);
    sink.formattedWrite("%s                  .toIRCEvent(bot);\n", 1.tabs);
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


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "users")
void onCommandShowUsers()
{
    logger.trace("Printing Admin's users");

    //printObject(state.bot);

    foreach (entry; state.users.byKeyValue)
    {
        writefln("%-12s [%s]", entry.key, entry.value);
    }
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "sudo")
void onCommandSudo(const IRCEvent event)
{
    state.mainThread.send(ThreadMessage.Sendline(), event.content);
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "fake")
void onCommandFake(const IRCEvent event)
{
    state.mainThread.send(event.content);
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "quit")
void onCommandQuit(const IRCEvent event)
{
    state.mainThread.send(ThreadMessage.Quit(), event.content);
}

@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "resetterm")
void onCommandResetTerminal()
{
    write(TerminalToken.reset);
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "printall")
void onCommandPrintAll()
{
    logger.info("Printing all: ", printAll);
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "printbytes")
void onCommandPrintBytes()
{
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "asserts")
void onCommandAsserts()
{
    formatBot(stdout.lockingTextWriter, state.bot);
}


@(IRCEvent.Type.ANY)
void onAnyEvent(const IRCEvent event)
{
    if (printAll) logger.trace(event.raw, '$');

    if (printBytes)
    {
        import std.string : representation;

        foreach (i, c; event.content.representation)
        {
            writefln("[%d] %s : %03d", i, cast(char)c, c);
        }
    }

    if (printAsserts)
    {
        import std.algorithm.searching : canFind;

        if ((cast(ubyte[])event.raw).canFind(1))
        {
            logger.warning("event.raw contains CTCP 1 which might not get printed");
        }

        formatEventAssertBlock(stdout.lockingTextWriter, event);
    }
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "join")
void onCommandJoin(const IRCEvent event)
{
}


@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "part")
void onCommandPart(const IRCEvent event)
{
}


void joinPartImpl(const string prefix, const IRCEvent event)
{
    import std.algorithm.iteration : joiner, splitter;
    import std.format : format;

    // The prefix could be in lowercase. Do we care?
    assert(((prefix == "JOIN") || (prefix == "PART")),
           "Invalid prefix passed to joinPartlImpl: " ~ prefix);

    if (!event.content.length)
    {
        logger.warning("No channels supplied...");
        return;
    }

    state.mainThread.send(ThreadMessage.Sendline(),
        "%s :%s".format(prefix, event.content.splitter(' ').joiner(",")));
}


public:

mixin BasicEventHandlers;
mixin OnEventImpl;


final class AdminPlugin : IRCPlugin
{
    mixin IRCPluginBasics;
}

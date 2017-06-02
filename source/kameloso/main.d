module kameloso.main;

import kameloso.constants;
import kameloso.common;
import kameloso.connection;
import kameloso.config;
import kameloso.irc;
import kameloso.plugins;

import std.concurrency;
import std.datetime : SysTime;

version (Windows)
shared static this()
{
    import core.sys.windows.windows;

    // If we don't set the right codepage, the normal Windows cmd terminal won't display
    // international characters like åäö.
    SetConsoleCP(CP_UTF8);
    SetConsoleOutputCP(CP_UTF8);
}

private:

/// State variables and configuration for the IRC bot.
IRCBot bot;

/// Runtime settings for bot behaviour.
Settings settings;

/// A runtime array of all plugins. We iterate this when we have an IRCEvent to react to.
IRCPlugin[] plugins;

/// A 1-buffer of IRCEvents to replay when a WHOIS call returns.
IRCEvent[string] replayQueue;

/// The socket we use to connect to the server.
Connection conn;

/// When a nickname was called WHOIS on, for hysteresis.
SysTime[string] whoisCalls;

/++
 +  Return value flag denoting whether the program should exit or not,
 +  after a function returns it.
 +/
alias Quit = Flag!"quit";


// checkMessages
/++
 +  Checks for concurrency messages and performs action based on what was received.
 +
 +  The return value tells the caller whether the received action means the bot should exit.
 +
 +  Returns:
 +      Quit.yes or Quit.no, depending.
 +/
Quit checkMessages()
{
    import core.time : seconds;

    scope (failure)
    {
        writeln(Foreground.lightred, "[main.checkMessages] FAILURE");
        foreach (plugin; plugins) plugin.teardown();
    }

    Quit quit;

    /// Echo a line to the terminal and send it to the server
    void sendline(ThreadMessage.Sendline, string line)
    {
        writeln(Foreground.white, "--> ", line);
        conn.sendline(line);
    }

    /// Send a line to the server without echoing it
    void quietline(ThreadMessage.Quietline, string line)
    {
        conn.sendline(line);
    }

    /// Send a ping "to" the server address saved in the bot.server struct
    void ping(ThreadMessage.Ping)
    {
        writeln(Foreground.white, "--> PING :", bot.server.resolvedAddress);
        conn.sendline("PING :", bot.server.resolvedAddress);
    }

    /// Send a WHOIS call to the server, and buffer the requests.
    void whois(ThreadMessage.Whois, IRCEvent event)
    {
        import std.datetime : Clock;

        // We buffer the request so only one goes out for a particular nickname
        // at any one given time.Identical requests are likely to go out several
        // at a time in bursts, and we only need one reply. So limit the calls.

        const then = (event.sender in whoisCalls);
        const now = Clock.currTime;

        if (then && (now - *then) < Timeout.whois.seconds) return;

        writeln(Foreground.white, "--> WHOIS :", event.sender);
        conn.sendline("WHOIS :", event.sender);
        whoisCalls[event.sender] = Clock.currTime;
        replayQueue[event.sender] = event;
    }

    /// Receive an updated bot, inherit it into .bot and propagate it to
    /// all plugins.
    void updateBot(shared IRCBot bot)
    {
        .bot = cast(IRCBot)bot;

        kameloso.irc.loadBot(.bot);

        foreach (plugin; plugins) plugin.newBot(.bot);
    }

    /// Receive new settings, inherit them into .settings and propagate
    /// them to all plugins.
    void updateSettings(Settings settings)
    {
        .settings = settings;

        foreach (plugin; plugins) plugin.newSettings(.settings);
    }

    /// Respond to PING with PONG to the supplied text as target.
    void pong(ThreadMessage.Pong, string target)
    {
        // writeln(Foreground.white, "--> PONG :", target);
        conn.sendline("PONG :", target);
    }

    /// Quit the server with the supplied reason.
    void quitServer(ThreadMessage.Quit, string reason)
    {
        // This will automatically close the connection.
        // Set quit to yes to propagate the decision down the stack.
        const line = reason.length ? reason : bot.quitReason;

        writeln(Foreground.white, "--> QUIT :", line);
        conn.sendline("QUIT :", line);

        foreach (plugin; plugins) plugin.teardown();

        quit = Quit.yes;
    }

    bool receivedSomething;

    do
    {
        // Use the bool of whether anything was received at all to decide if the loop should
        // continue. That way we neatly exhaust the mailbox before returning.
        receivedSomething = receiveTimeout(0.seconds,
            &sendline,
            &ping,
            &whois,
            &updateBot,
            &quietline,
            &pong,
            &quitServer,
            (Variant v)
            {
                // Caught an unhandled message
                writeln(Foreground.lightred, "Main thread received unknown Variant");
                writeln(Foreground.lightred, v);
            }
        );
    }
    while (receivedSomething && !quit);

    return quit;
}


// handleArguments
/++
 +  Read command-line options and merge them with those in the configuration file.
 +
 +  The priority of options then becomes getopt over config file over hardcoded defaults.
 +
 +  Params:
 +      The string[] args the program was called with.
 +
 +  Returns:
 +      Quit.yes or no depending on whether the arguments chosen mean the program
 +      should not proceed.
 +/
Quit handleArguments(string[] args)
{
    import std.getopt;
    import std.format : format;

    bool shouldWriteConfig;
    GetoptResult getoptResults;

    try
    {
        arraySep = ",";

        getoptResults = args.getopt(
            config.caseSensitive,
            "n|nickname",    "Bot nickname", &bot.nickname,
            "u|user",        "Username when registering onto server (not nickname)", &bot.user,
            "i|ident",       "IDENT string", &bot.ident,
            "pass",          "Registration password (not auth or nick services)", &bot.pass,
            "a|auth",        "Auth service login name, if applicable", &bot.authLogin,
            "p|authpassword","Auth service password", &bot.authPassword,
            "m|master",      "Auth login of the bot's master, who gets " ~
                            "access to administrative functions", &bot.master,
            "H|home",        "Home channels to operate in, comma-separated" ~
                            " (remember to escape or enquote the #s!)", &bot.homes,
            "C|channel",     "Non-home channels to idle in, comma-separated" ~
                            " (ditto)", &bot.channels,
            "s|server",      "Server address", &bot.server.address,
            "P|port",        "Server port", &bot.server.port,
            "c|config",      "Read configuration from file (default %s)"
                             .format(Settings.init.configFile), &settings.configFile,
            "w|writeconfig", "Write configuration to file", &shouldWriteConfig,
        );
    }
    catch (Exception e)
    {
        // User misspelled or supplied an invalid argument; error out and quit
        writeln(Foreground.lightred, e.msg);
        return Quit.yes;
    }

    if (getoptResults.helpWanted)
    {
        defaultGetoptPrinter(colourise(Foreground.lightgreen) ~
                            "Command-line arguments available:\n" ~
                            colourise(Foreground.default_),
                            getoptResults.options);
        writeln();
        return Quit.yes;
    }

    // Read settings into temporary Bot and Settings structs, then meld them into the
    // real ones into which command-line arguments will have been applied.

    IRCBot botFromConfig;
    Settings settingsFromConfig;

    settings.configFile.readConfig(botFromConfig, botFromConfig.server, settingsFromConfig);

    botFromConfig.meldInto(bot);
    settingsFromConfig.meldInto(settings);

    bot.server.resolveNetwork();

    // If --writeconfig was supplied we should just write and quit

    if (shouldWriteConfig)
    {
        writeConfigToDisk();
        return Quit.yes;
    }

    return Quit.no;
}


/// Resets and initialises all plugins.
void initPlugins()
{
    foreach (plugin; plugins) plugin.teardown();

    IRCPluginState state;
    state.bot = bot;
    state.settings = settings;
    state.mainThread = thisTid;
    state.bot.server.resolveNetwork();  // neccessary?

    // Register function to run when the IRC parser wants to propagage
    // a change to the IRCBot

    static void onNewBotFunction(const IRCBot bot)
    {
        import std.concurrency : send, thisTid;

        thisTid.send(cast(shared)bot);
    }

    IRCParserHooks hooks;
    hooks.onNewBot = &onNewBotFunction;
    kameloso.irc.registerParserHooks(hooks);
    kameloso.irc.loadBot(state.bot);

    // TODO: Somehow move this list somewhere else
    plugins = cast(IRCPlugin[])
    [
        new Printer(state),
        new SedReplacePlugin(state),
        new AdminPlugin(state),
        new NotesPlugin(state),
        new Chatbot(state),
        new ConnectPlugin(state),
        new CTCPPlugin(state),
    ];

    version (Webtitles)
    {
        plugins ~= new Webtitles(state);
    }

    version (Posix)
    {
        plugins ~= new Pipeline(state);
    }
}

/// Writes the current configuration to the config file specified in the Settings.
void writeConfigToDisk()
{
    writeln(Foreground.lightcyan, "Writing configuration to ", settings.configFile);
    settings.configFile.writeConfig(bot, bot.server, settings);
    writeln();
    printObjects(bot, bot.server, settings);
}


public:


version (unittest)
void main() {
    // Compiled with -b unittest, so run the tests and exit.
    writeln("Tests passed!");
}
else
int main(string[] args)
{
    writefln(Foreground.white,
             "kameloso IRC bot v%s, built %s\n$ git clone %s\n",
             cast(string)kamelosoInfo.version_,
             cast(string)kamelosoInfo.built,
             cast(string)kamelosoInfo.source);

    if (handleArguments(args) == Quit.yes) return 0;

    // Print the current settings to show what's going on.
    printObjects(bot, bot.server, settings);

    if (!bot.homes.length && !bot.master.length && !bot.friends.length)
    {
        import std.path : baseName;

        writeln("No master nor channels configured!");
        writefln("Use %s --writeconfig to generate a configuration file.",
                 args[0].baseName);

        return 1;
    }

    // Save the original nickname *once*, outside the connection loop
    bot.origNickname = bot.nickname;

    Quit quit;
    do
    {
        conn.reset();
        conn.resolve(bot.server.address, bot.server.port);
        conn.connect();

        if (!conn.connected) return 1;

        // Reset fields in the bot that should not survive a reconnect
        bot.startedRegistering = false;
        bot.finishedRegistering = false;
        bot.startedAuth = false;
        bot.finishedAuth = false;
        bot.server.resolvedAddress = string.init;

        initPlugins();

        auto generator = new Generator!string(() => listenFiber(conn));
        quit = loopGenerator(generator);
    }
    while (!quit);

    return 0;
}


// loopGenerator
/++
 +  This loops over the Generator fiber that's reading from the socket. Full lines are
 +  yielded in the Generator to be caught here, consequently parsed into IRCEvents, and then
 +  dispatched to all the plugins.
 +
 +  Params:
 +      generator = a string-returning Generator that's reading from the socket.
 +
 +  Returns:
 +      Quit.yes if circumstances mean the bot should exit, otherwise Quit.no.
 +/
Quit loopGenerator(Generator!string generator)
{
    import core.thread : Fiber;

    Quit quit;

    while (!quit)
    {
        if (generator.state == Fiber.State.TERM)
        {
            // Listening Generator disconnected; reconnect
            generator.reset();

            return Quit.no;
        }

        generator.call();

        foreach (immutable line; generator)
        {
            // Empty line yielded means nothing received
            if (!line.length) break;

            // Hopefully making the event immutable means less gets copied?
            immutable event = line.toIRCEvent();

            bool spammedAboutReplaying;

            foreach (plugin; plugins)
            {
                plugin.onEvent(event);

                if ((event.type == IRCEvent.Type.WHOISLOGIN) ||
                    (event.type == IRCEvent.Type.HASTHISNICK))
                {
                    const savedEvent = event.target in replayQueue;
                    if (!savedEvent) continue;

                    if (!spammedAboutReplaying)
                    {
                        writeln(Foreground.white, "Replaying event:");
                        printObjects(*savedEvent);
                        spammedAboutReplaying = true;
                    }

                    plugin.onEvent(*savedEvent);
                }
            }

            if ((event.type == IRCEvent.Type.WHOISLOGIN) ||
                (event.type == IRCEvent.Type.HASTHISNICK))
            {
                replayQueue.remove(event.target);
            }
        }

        quit = checkMessages();
    }

    return Quit.yes;
}

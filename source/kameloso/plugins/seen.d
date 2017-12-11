/++
 +  This is an example plugin.
 +
 +  We will be writing a plugin with `seen` functionality; the ability for
 +  someone to query when a given nickname was last seen online.
 +
 +  We will implement this by keeping an internal `JSON` array of nicknames
 +  paired with timestamps. Whenever we see a user do something, we will update
 +  his or her timestamp with the current time. We'll save this array to disk
 +  when closing the program and read it from file when starting it.
 +
 +  To be more thorough we will also query the server for the users in our home
 +  channels, once per `PING`. This will give us a bit more precision, as it
 +  will catch users who otherwise haven't performed any action we were
 +  listening for. Otherwise, a completely silent participant will never get
 +  recorded as being seen.
 +
 +  kameloso does not use callbacks, but instead annotate functions with `UDA`s,
 +  or *User Defined Annotations*. In essence, we will tag our functions with
 +  the kind or kinds of IRC events that should invoke them. Annotations look
 +  like so:
 +
 +  --------------
 +  @SomeUDA
 +  @(SomeUDA)
 +  @5
 +  @("some string")
 +  void foo() {}
 +  --------------
 +
 +  Any* symbol can have an UDA, not just functions. We will annotate one
 +  "settings" variable later, to make its content be automatically saved to
 +  and read from the configuration file.
 +/

/++
 +  A file is implicitly a module, but we name ourselves here to make it easier
 +  to import it elsewhere. An import is not an `#include`; the content is not
 +  pasted wherever imported, but allows for sane symbol lookup without* the
 +  worry of cyclic dependencies.
 +/
module kameloso.plugins.seen;

/// We need things from `kameloso.plugins.common` for obvious reasons, so we
/// import it.
import kameloso.plugins.common;

/// Likewise `kameloso.ircdefs` for the definitions of an IRC event.
import kameloso.ircdefs;

/// `kameloso.common` is also a good idea; we will need it when we want to send
/// text to the server.
import kameloso.common;

/// `std.json` for our `JSON` storage.
import std.json;

/// `std.stdio` may come in handy if we want to debug something.
import std.stdio;


/++
 +  Most of the plugin can be kept private. There is one exceptions that we will
 +  take care of at the end of the file, but the rest might as well be hidden to
 +  the outside world.
 +
 +  Even if something is private it will be visible to eveything in the same
 +  module, so we're essentially only limiting what other modules can see.
 +/
private:


/++
 +  We want our plugin to be *configurable* with a section for itself in the
 +  configuration file. For this purpose we create a `Settings` struct housing
 +  our configurable bits.
 +
 +  If the name ends with "Settings", that will be stripped from its section
 +  header in the file. Hence, this plugin will get the header `[Seen]`.
 +
 +  Each member of the struct will be given its own line in there.
 +/
struct SeenSettings
{
    /// A file to persistently store our seen users inbetween executions.
    string seenFile = "seen.conf";
}

/++
 +  We need one instance of those settings, and we annotate it `@Settings`.
 +  This is the hook that makes the program save the `SeenSettings` in the
 +  configuration file. Merely annotate it such and it'll be there.
 +/
//@Settings SeenSettings seenSettings;


// IRCPluginState
/++
 +  The `IRCPluginState` is a struct housing various variables that together
 +  make the plugin's *state*. This is where information is kept about the bot,
 +  the server, and some metathings allowing us to send messages to the server.
 +
 +  --------------
 +  struct IRCPluginState
 +  {
 +      IRCBot bot;
 +      CoreSettings settings;
 +      Tid mainThread;
 +      IRCUser[string] users;
 +      WHOISRequest[string] whoisQueue;
 +  }
 +  --------------
 +
 +  * `bot` houses information about the bot itself, and the server you're
 +    connected to.
 +
 +  * `settings` contains a few program-wide settings, not specific to a plugin.
 +
 +  * `mainThread` is the *thread ID* of the thread running the main loop. We
 +    will use it to send messages to the server, via concurrency messages to
 +    it.
 +
 +  * `users` is an associative array keyed with users' nicknames. The value to
 +     that key is an `IRCUser` representing that user in terms of nickname,
 +     address, ident, and nickname services login. This is a way to keep
 +     track of users by more than merely their name. It is however not saved at
 +     the end of the program; it is merely state.
 +
 +  * `whoisQueue` is also an associative array into which we place
 +    `WHOISRequest`s. The main loop will pick up on these and call `WHOIS` on
 +     the nickname in the key. A `WHOISRequest` is otherwie just an `IRCEvent`
 +     to be played back when the `WHOIS` results return, as well as a function
 +     pointer to call with that event.
 +/
//IRCPluginState state;

/++
 +  Our JSON storage of seen users; an array keyed with users' nicknames and
 +  with values that are UNIX timetamps, denoting when that user was last seen.
 +  It is in essence an associative array of type `long[string]`, where the
 +  string key is the nickname and the long the timestamp.
 +
 +  --------------
 +  seenUsers["joe"] = Clock.currTime.toUnixTime;
 +  auto now = Clock.currTime.toUnixTime;
 +  writeln("Seconds since we last saw joe: ", (now - seenUsers["joe"].integer));
 +  --------------
 +/
//JSONValue seenUsers;


// onSomeAction
/++
 +  Whenever a user does something, record this user as being seen at the
 +  current time.
 +
 +  This function will be called whenever an `IRCEvent` is being processed of
 +  the `IRCEvent.Type`s that we annotate the function with. There are still no
 +  callbacks involved.
 +
 +  The `ChannelPolicy` annotation decides whether this function should be
 +  called based on the `channel` the event took place in, if applicable.
 +  The two policies are `homeOnly`, in which only events in channels in the
 +  `homes` array will be allowed to trigger this; or `any`, in which case
 +  anywhere goes.
 +/
@(Chainable)
@(IRCEvent.Type.EMOTE)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.JOIN)
@(IRCEvent.Type.PART)
@(IRCEvent.Type.QUIT)
@(ChannelPolicy.homeOnly)
void onSomeAction(SeenPlugin plugin, const IRCEvent event)
{
    /++
     +  This will, as such, be automatically called on `EMOTE`, `QUERY`, `JOIN`,
     +  `PART` and `QUIT` events. Furthermore, in the case where there is a
     +  channel (all but `QUIT`), it will only trigger if it took place in a
     +  home channel.
     +
     +  Update the user's timestamp to the current time.
     +/
    plugin.updateUser(event.sender.nickname);
}


// onNames
/++
 +  Whenever a channel has its members enumerated, such as when requesting
 +  `WHO #channel`, it returns several replies, one per each user in the
 +  channel. The default in the `Connect` plugin is to do this automatically
 +  when joining a channel.
 +
 +  Catch each user listed and update their entries in the seen users list,
 +  creating them if they don't exist.
 +/
@(IRCEvent.Type.RPL_WHOREPLY)
@(ChannelPolicy.homeOnly)
void onWHOReply(SeenPlugin plugin, const IRCEvent event)
{
    /// Update the user's entry in the JSON storage.
    plugin.updateUser(event.target.nickname);
}


/++
 +  When requesting `NAMES` on a channel, the server will do a big list of every
 +  participant in it, in a big string of nicknames separated by spaces. This
 +  is done automatically when you join a channel.
 +
 +  We want to catch that as well and record each person as having been seen.
 +/
@(IRCEvent.Type.RPL_NAMREPLY)
@(ChannelPolicy.homeOnly)
void onNameReply(SeenPlugin plugin, const IRCEvent event)
{
    import std.algorithm.iteration : splitter;
    /++
     +  Use a `splitter` to iterate each name and call `updateUser` to update
     +  (or create) their entry in the seenUsers `JSON` storage.
     +/
    foreach (const nickname; event.content.splitter(" "))
    {
        plugin.updateUser(nickname);
    }
}


/++
 +  When the batch of `RPL_NAMREPLY` and/or `RPL_WHOREPLY` events end (and there
 +  may be a *lot* of replies) an `RPL_ENDOFNAMES` and `RPL_ENDOFWHO` event is
 +  always fired, respectively.
 +
 +  We know there are likely some outstanding changes from all the
 +  `RPL_NAMREPLY` and/or `RPL_WHOREPLY` events, so use this as a hook to
 +  batch-save all seen nicknames to disk. It's as good a time as any.
 +/
@(IRCEvent.Type.RPL_ENDOFWHO)
@(IRCEvent.Type.RPL_ENDOFNAMES)
void onEndOfNames(SeenPlugin plugin)
{
    /// Save seen users to disk as persistent storage.
    plugin.seenUsers.saveSeen(plugin.seenSettings.seenFile);
}


// onPing
/++
 +  Whenever an `IRCEvent` of type `PING` occurs, query each home channel for a
 +  list of their users with `WHO`.
 +
 +  If we ride the periodicity of `PING` we get a natural cadence that queries
 +  the channels occasionally enough.
 +/
@(IRCEvent.Type.PING)
void onPing(SeenPlugin plugin)
{
    /// Twitch servers don't support `WHO` commands.
    if (plugin.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    foreach (const channel; plugin.state.bot.homes)
    {
        import std.concurrency : send;

        /++
         +  The bot uses concurrency messages to queue strings to be sent to the
         +  server. This has benefits such as that even a multi-threaded program
         +  will have synchronous messages sent, and it's overall an easy and
         +  convenient way for plugin to send messages up the stack.
         +
         +  Future work may change this.
         +
         +  The `ThreadMessage.Sendline` is one of several concurrency message
         +  "types" defined in `kameloso.common`, and this is why we wanted to
         +  import that.
         +/
        plugin.state.mainThread.send(ThreadMessage.Quietline(), "WHO " ~ channel);
    }
}


// onCommandSeen
/++
 +  Whenever someone says "seen" in a `CHAN` or a `QUERY`, and if `CHAN` then
 +  only if in a *home*, process this function.
 +
 +  The `Prefix` annotation defines a piece of text that the incoming message
 +  must start with for this function to be called. `NickPolicy` deals with
 +  whether the message has to start with the name of the *bot* or not, and to
 +  what extent. It can be one of:
 +  * `optional`, where the bot's nickname will be allowed and stripped away,
 +    but the function will still be invoked given the right prefix string.
 +  * `required`, where the message has to start with the name of the bot if in
 +    a `CHAN` message, but it needn't be there in a `QUERY`.
 +  * `hardRequired`, where the message *has* to start with the bot's nickname
 +    at all times, or this function will not be called.
 +
 +  The `IRCEvent` will probably look something like this:
 +
 +  --------------
 +  event.sender.nickname = "foo";
 +  event.sender.ident = "~bar";
 +  event.sender.address = "baz.foo.bar.org";
 +  event.channel = "#bar";
 +  event.content = "Joe";
 +  --------------
 +
 +  The plugin system will have made certain we only get messages starting with
 +  "seen", since we annotated this funtcion with such a `Prefix`. It will since
 +  have been sliced off, so we're left only with the "arguments" to "seen".
 +
 +  If this is a `CHAN` event, the original lines was probably
 +  "`kameloso: seen Joe`". If it was a `QUERY`, the `kameloso:` prefix may have
 +  been omitted. In either case, we're left with only the parts we're
 +  interested in, and the rest sliced off.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(ChannelPolicy.homeOnly)
@(PrivilegeLevel.friend)
@Prefix("seen")
@Prefix(NickPolicy.required, "seen")
void onCommandSeen(SeenPlugin plugin, const IRCEvent event)
{
    import kameloso.string : timeSince;
    import std.concurrency : send;
    import std.datetime : Clock, SysTime;
    import std.format : format;

    immutable target = event.channel.length ?
        event.channel : event.sender.nickname;

    if (event.sender.nickname == event.content)
    {
        plugin.state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :That's you!"
            .format(target));
        return;
    }

    const userTimestamp = event.content in plugin.seenUsers;

    if (!userTimestamp)
    {
        plugin.state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :I have never seen %s."
            .format(target, event.content));
        return;
    }

    const timestamp = SysTime.fromUnixTime((*userTimestamp).integer);
    immutable elapsed = timeSince(Clock.currTime - timestamp);

    plugin.state.mainThread.send(ThreadMessage.Sendline(),
        "PRIVMSG %s :I last saw %s %s ago."
        .format(target, event.content, elapsed));
}


// onCommandPrintSeen
/++
 +  As a tool to help debug, print the current `seenUsers` JSON storage to the
 +  local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(ChannelPolicy.homeOnly)
@(PrivilegeLevel.master)
@Prefix(NickPolicy.required, "printseen")
void onCommandPrintSeen(SeenPlugin plugin)
{
    writeln(plugin.seenUsers.toPrettyString);
}


// updateUser
/++
 +  Update a given nickname's entry in the `JSON` seen storage with the current
 +  time, expressed in UNIX time.
 +/
void updateUser(SeenPlugin plugin, const string nickname)
{
    import kameloso.irc : stripModeSign;
    import std.datetime : Clock;

    /// Make sure to strip the modesign, so @foo is the same person as foo.
    plugin.seenUsers[nickname.stripModeSign] = Clock.currTime.toUnixTime;
}


// loadSeenFile
/++
 +  Given a filename, read the contents and load it into a `JSON` storage
 +  variable, and return it. If there was no file there to read, return an empty
 +  but initialised `JSONValue` object.
 +/
JSONValue loadSeenFile(const string filename)
{
    import std.file   : exists, isFile, readText;
    import std.json   : parseJSON;

    if (!filename.exists || !filename.isFile)
    {
        logger.info(filename, " does not exist or is not a file");
        JSONValue newJSON;
        newJSON.object = null;  // this is the weirdest thing but it works
        return newJSON;
    }

    immutable wholeFile = filename.readText;
    return parseJSON(wholeFile);
}


// saveSeen
/++
 +  Saves the passed `JSONValue` storage to disk.
 +/
void saveSeen(const JSONValue jsonStorage, const string filename)
{
    import std.ascii : newline;
    import std.file  : exists, isFile, remove;

    if (filename.exists && filename.isFile)
    {
        remove(filename); // Wise?
    }

    auto file = File(filename, "a");

    file.write(jsonStorage.toPrettyString);
    file.write(newline);
}


// start
/++
 +  Late during program start, when connection has just been established, load
 +  the seen users from file.
 +/
void start(IRCPlugin rawPlugin)
{
    auto plugin = cast(SeenPlugin)rawPlugin;
    plugin.seenUsers = loadSeenFile(plugin.seenSettings.seenFile);
}


// teardown
/++
 +  When closing the program or when crashing with grace, save the seen users
 +  array to disk for later re-reading.
 +/
void teardown(IRCPlugin basePlugin)
{
    auto plugin = cast(SeenPlugin)basePlugin;
    plugin.seenUsers.saveSeen(plugin.seenSettings.seenFile);
}


/++
 +  BasicEventHandlers is a *mixin template*; a few functions defined in
 +  `kameloso.plugins.common` to deal with common housekeeping that every plugin
 +  wants done. Mixing it in copies and pastes it here.
 +
 +  It's boilerplate so you don't have to deal with some very basic things, like
 +  managing users saved in our `IRCPluginState.users` array. It is not
 +  mandatory but highly recommended in the vast majority of cases.
 +/
mixin BasicEventHandlers;


// We're done with all private bits, remaining is the thing that must be public.
public:


// SeenPlugin
/++
 +  This is your plugin to the outside world, the only thing visible in the
 +  entire mdule. It only serves as a way of proxying calls to our top-level
 +  private functions.
 +/
final class SeenPlugin : IRCPlugin
{
    @Settings SeenSettings seenSettings;

    JSONValue seenUsers;
    /++
     +  The final mixin and the final piece of the puzzle.
     +
     +  This mixes in functions that fully implement an `IRCPlugin`. They don't
     +  do much by themselves other than call the module's functions.
     +
     +  As an exception, it mixes in contains the bits needed to automatically
     +  call functions based on their `IRCEvent.Type` annotations. It is
     +  mandatory, if you want things to work.
     +
     +  Seen from any other module, this module is a big block of private things
     +  they can't see, plus this visible plugin class. By having this class
     +  pass on things to the private functions we limit the surface area of
     +  the plugin to be really small.
     +/
    mixin IRCPluginImpl;
}

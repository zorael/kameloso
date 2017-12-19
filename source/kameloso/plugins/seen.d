/++
 +  This is an example plugin.
 +
 +  We will be writing a plugin with `seen` functionality; the ability for
 +  someone to query when a given nickname was last seen online.
 +
 +  We will implement this by keeping an internal `JSON` array of nicknames
 +  paired with timestamps. Whenever we see a user do something, we will update
 +  his or her timestamp with the current time. We'll save this array to disk
 +  when closing the program and read it from file when starting it, as well as
 +  occasionally once every few hours.
 +
 +  To be more thorough we will also query the server for the users in our home
 +  channels, once per `PING`. Pings occur once every few minutes. This will
 +  give us a bit more precision, as it will catch users who otherwise haven't
 +  performed any action we were listening for. Otherwise, a completely silent
 +  participant will never get recorded as being seen.
 +
 +  kameloso does not use callbacks, but instead annotates functions with
 +  `UDA`s, or *User Defined Annotations*. In essence, we will tag our functions
 +  with the kind or kinds of IRC events that should invoke them.
 +
 +  Annotations look like so:
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

/++
 +  We'll want to import parts of the rest of the program, else it won't
 +  function.
 +
 +  We need things from `kameloso.plugins.common` for obvious reasons, so we
 +  import that.
 +/
import kameloso.plugins.common;

/// Likewise `kameloso.ircdefs`, for the definitions of an IRC event.
import kameloso.ircdefs;

/++
 +  `kameloso.common` is also a good idea; we will need it when we want to send
 +  text to the server.
 +/
import kameloso.common;

/// FIXME
import kameloso.outgoing;

/// `std.json` for our `JSON` storage.
import std.json;

/// `std.stdio` may come in handy if we want to printf-debug something.
import std.stdio;


/++
 +  Most of the module can (and ideally should) be kept private. Even if
 +  something is private it will be visible to eveything in the same module, so
 +  we're essentially only limiting what other modules can see.
 +
 +  Our surface area here will be only one `IRCPlugin` class, which we'll define
 +  in the end.
 +/
private:


/++
 +  We want our plugin to be *configurable* with a section for itself in the
 +  configuration file. For this purpose we create a "Settings" struct housing
 +  our configurable bits.
 +
 +  If the name ends with "Settings", that will be stripped from its section
 +  header in the file. Hence, this plugin will get the header `[Seen]`.
 +
 +  Each member of the struct will be given its own line in there.
 +
 +  We will leave it for now; just know that we'll be able to access any
 +  settings therein from elsewhere in the plugin.
 +/
struct SeenSettings
{
    /// How often to save seen users to disk (aside from program exit).
    int hoursBetweenSaves = 6;

    /+
     +  The filename to which to persistently store our list of seen users
     +  between executions of the program.
     +/
    string seenFile = "seen.conf";
}


// onSomeAction
/++
 +  Whenever a user does something, record this user as being seen at the
 +  current time.
 +
 +  This function will be called whenever an `IRCEvent` is being processed of
 +  the `IRCEvent.Type`s that we annotate the function with. There are still no
 +  callbacks involved.
 +
 +  The `Chainable` annotations mean that the plugin will also process other
 +  functions with the same `IRCEvent.Type` annotations, even if this one
 +  matched. The default is otherwise that it will end early after one match,
 +  but this doesn't ring well with catch-all functions like these. It's faster
 +  to save `Chainable` for the functions that actually need it.
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
@(ChannelPolicy.homeOnly)
void onSomeAction(SeenPlugin plugin, const IRCEvent event)
{
    /++
     +  This will, as such, be automatically called on `EMOTE`, `QUERY`, `JOIN`,
     +  and `PART` events. Furthermore, it will only trigger if it took place in
     +  a home channel.
     +
     +  It says `plugin.updateUser(...)` but there is no method `updateUser` in
     +  the `SeenPlugin plugin`. This is an example of *UFCS*, or Uniform
     +  Function Call Syntax. It is rewritten into `updateUser(plugin, ...)`,
     +  and we'll make heavy use of it. With it, top-level functions can act as
     +  *pseudomembers* of (here) `SeenPlugin`. Virtually the entirety of our
     +  implementation will be top-level, outside of the `SeenPlugin`, and then
     +  called like this to act as if they were class member methods.
     +
     +  Update the user's timestamp to the current time.
     +/
    plugin.updateUser(event.sender.nickname);
}


// onWHOReply
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
 +  is done automatically when you join a channel. Nicknames are prefixed with
 +  mode signs if they are operators, voiced or similar, so we'll need to strip
 +  that away.
 +
 +  We want to catch the `NAMES` reply and record each person as having been
 +  seen.
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
    foreach (const signed; event.content.splitter(" "))
    {
        import kameloso.irc : stripModeSign;

        immutable nickname = signed.stripModeSign();
        if (nickname == plugin.state.bot.nickname) continue;

        plugin.updateUser(nickname);
    }
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
    with (plugin)
    {
        /// Twitch servers don't support `WHO` commands.
        if (state.bot.server.daemon == IRCServer.Daemon.twitch) return;

        foreach (const channel; state.bot.homes)
        {
            import std.concurrency : send;

            /++
             +  The bot uses concurrency messages to queue strings to be sent to
             +  the server. This has benefits such as that even a multi-threaded
             +  program will have synchronous messages sent, and it's overall an
             +  easy and convenient way for plugin to send messages up the
             +  stack.
             +
             +  Future work may change this.
             +
             +  The `ThreadMessage.Sendline` is one of several concurrency
             +  message "types" defined in `kameloso.common`, and this is part
             +  of why we wanted to import that.
             +/
            plugin.toServer.raw("WHO " ~ channel);
        }

        import std.datetime.systime : Clock;

        const now = Clock.currTime;

        /// Once every n hours, save the JSON storage to disk.
        if ((seenSettings.hoursBetweenSaves > 0) && (now.hour == nextHour))
        {
            nextHour = (nextHour + seenSettings.hoursBetweenSaves) % 24;
            seenUsers.saveSeen(seenSettings.seenFile);
        }
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
 +     but the function will still be invoked given the right prefix string.
 +  * `required`, where the message has to start with the name of the bot if in
 +     a `CHAN` message, but it needn't be there in a `QUERY`.
 +  * `hardRequired`, where the message *has* to start with the bot's nickname
 +     at all times, or this function will not be called.
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
 +  "seen", since we annotated this function with such a `Prefix`. It will since
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
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    if (event.sender.nickname == event.content)
    {
        // The person is asking for seen information about him-/herself.
        plugin.toServer.privmsg(event.channel, event.sender.nickname, "That's you!");
        return;
    }

    const userTimestamp = event.content in plugin.seenUsers;

    if (!userTimestamp)
    {
        // No matches for nickname `event.content` in `plugin.seenUsers`.

        plugin.toServer.privmsg(event.channel, event.sender.nickname,
            "I have never seen %s."
            .format(event.content));
        return;
    }

    const timestamp = SysTime.fromUnixTime((*userTimestamp).integer);
    immutable elapsed = timeSince(Clock.currTime - timestamp);

    plugin.toServer.privmsg(event.channel, event.sender.nickname,
        "I last saw %s %s ago."
        .format(event.content, elapsed));
}


// onCommandPrintSeen
/++
 +  As a tool to help debug, print the current `seenUsers` JSON storage to the
 +  local terminal.
 +
 +  The `PrivilegeLevel` annotation dictates who is authorised to trigger the
 +  function. It has three modes; `anyone`, `friend` and `master`.
 +
 +  * `anyone` will let precisely anyone trigger it, without looking them up.
 +  * `friend will look whoever up and compare their *services login* with the
 +  *  whitelist in the `friends` array in the configuration file.
 +  * `master` will allow only you. It will still look you up, but compare your
 +     services login name with the one in the `master` field in the
 +     configuration file.
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
 +
 +  This is not annotated with an IRC event type and will merely be invoked from
 +  elsewhere, like any normal function.
 +/
void updateUser(SeenPlugin plugin, const string nickname)
{
    import kameloso.irc : stripModeSign;
    import std.datetime.systime : Clock;

    /// Make sure to strip the modesign, so `@foo` is the same person as `foo`.
    plugin.seenUsers[nickname.stripModeSign()] = Clock.currTime.toUnixTime;
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
    auto file = File(filename, "w");

    file.write(jsonStorage.toPrettyString);
    file.writeln();
}


// onEndOfMotd
/++
 +  After we have registered on the server and seen the message of the day spam,
 +  load our seen users from file.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd(SeenPlugin plugin)
{
    import std.datetime.systime : Clock;

    with (plugin)
    {
        seenUsers = loadSeenFile(seenSettings.seenFile);

        if ((seenSettings.hoursBetweenSaves > 24) ||
            (seenSettings.hoursBetweenSaves < 0))
        {
            logger.warning("Invalid setting for hours between saves: ",
                seenSettings.hoursBetweenSaves);
            logger.warning("It must be a number between 1 and 24 (0 disables)");

            seenSettings.hoursBetweenSaves = 0;
        }
        else if (seenSettings.hoursBetweenSaves > 0)
        {
            // Initialise nextHour to occur in `hoursBetweenSaves` hours
            nextHour = (nextHour + seenSettings.hoursBetweenSaves) % 24;
        }
    }
}


// teardown
/++
 +  When closing the program or when crashing with grace, save the seen users
 +  array to disk for later re-reading.
 +/
void teardown(IRCPlugin basePlugin)
{
    SeenPlugin plugin = cast(SeenPlugin)basePlugin;
    plugin.seenUsers.saveSeen(plugin.seenSettings.seenFile);
}


/++
 +  BasicEventHandlers is a *mixin template*; a few functions defined in
 +  `kameloso.plugins.common` to deal with common housekeeping that every plugin
 +  wants done. Mixing it in copies and pastes it here.
 +
 +  It's boilerplate so you don't have to deal with some very basic things. It
 +  is not mandatory but highly recommended in nearly all cases.
 +/
mixin BasicEventHandlers;


/++
 +  Finally, our public bits.
 +/
public:


// SeenPlugin
/++
 +  This is your plugin to the outside world, the only thing visible in the
 +  entire module. It only serves as a way of proxying calls to our top-level
 +  private functions.
 +
 +  It also houses this plugin's *state*, notably its instance of `SeenSettings`
 +  and its `IRCPluginState`.
 +
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
 +     connected to.
 +
 +  * `settings` contains a few program-wide settings, not specific to a plugin.
 +
 +  * `mainThread` is the *thread ID* of the thread running the main loop. We
 +     will use it to send messages to the server, via concurrency messages to
 +     it.
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
final class SeenPlugin : IRCPlugin
{
    /++
     +  An instance of *settings* for the Seen plugin. We defined this at the
     +  top; the members of it will be saved to and loaded from the
     +  configuration file, for use in our module. Merely annotating it
     +  `@Settings` will ensure it ends up there.
     +/
    @Settings SeenSettings seenSettings;

    /++
     +  The next hour we should save to disk. We set it up to do it
     +  occasionally, once every `seenSettings.hoursBetweenSaves`.
     +/
    uint nextHour;

    /++
     +  Our JSON storage of seen users; an array keyed with users' nicknames and
     +  with values that are UNIX timetamps, denoting when that user was last
     +  seen. It is in essence an associative array or dictionary of type
     +  `long[string]`, where the `string` key is the nickname and the `long`
     +  the timestamp.
     +
     +  --------------
     +  seenUsers["joe"] = Clock.currTime.toUnixTime;
     +  auto now = Clock.currTime.toUnixTime;
     +  writeln("Seconds since we last saw joe: ", (now - seenUsers["joe"].integer));
     +  --------------
     +/
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

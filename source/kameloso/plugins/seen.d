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
 +  occasionally once every few (configurable) hours.
 +
 +  We will rely on the `ChanQueriesPlugin` (in `chanqueries.d`) to query
 +  channels for full lists of users upon joining new ones, including the ones
 +  we join upon connecting. Elsewise, a completely silent user will never be
 +  recorded as having been seen, as they would never be triggering any of the
 +  functions we define.
 +
 +  kameloso does primarily not use callbacks, but instead annotates functions
 +  with `UDA`s, or *User Defined Annotations*. In essence, we will tag our
 +  functions with the kind or kinds of IRC events that should invoke them.
 +
 +  Callback `Fiber`s *are* supported but are not in any large-scale use. They
 +  can be registered to process on incoming events, or timed with a worst-case
 +  precision of roughly `kameloso.constants.Timeout.receive` *
 +  `(kameloso.main.mainLoop).checkTimedFibersEveryN` + 1 seconds.
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
 +
 +  TODO with this plugin:
 +  * replace runtime JSON use with a direct associative array, and only convert
 +    it to JSON for saving.
 +  * add a timer system and update the periodic saving to make use of that.
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

/// `kameloso.common` for the instance of the *logger*.
import kameloso.common : logger;

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
@(IRCEvent.Type.QUIT)
@(PrivilegeLevel.anyone)
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


// onNick
/++
 +  When someone changes nickname, move the old seen timestamp to a new entry
 +  for the new nickname, and remove the old one.
 +/
@(Chainable)
@(IRCEvent.Type.NICK)
@(PrivilegeLevel.anyone)
void onNick(SeenPlugin plugin, const IRCEvent event)
{
    // There may not be an old one if the user was not indexed upon us joinng
    // the channel, which is the case with homeOnly and non-home channels.
    if (auto user = event.sender.nickname in plugin.seenUsers)
    {
        plugin.seenUsers[event.target.nickname] = *user;
        plugin.seenUsers.remove(event.sender.nickname);
    }
    else
    {
        plugin.updateUser(event.target.nickname);
    }
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
 +  When requesting `NAMES` on a channel, the server will send a big list of
 +  every participant in it, in a big string of nicknames separated by spaces.
 +  This is done automatically when you join a channel. Nicknames are prefixed
 +  with mode signs if they are operators, voiced or similar, so we'll need to
 +  strip that away.
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
     +  (or create) their entry in the seenUsers associative array.
     +/
    foreach (const signed; event.content.splitter(" "))
    {
        import kameloso.irc : stripModesign;
        import kameloso.string : has, nom;

        string nickname = signed;

        if (nickname.has('!'))
        {
            // SpotChat-like, signed is in full nick!ident@address form
            nickname = nickname.nom('!');
        }

        plugin.state.bot.server.stripModesign(nickname);
        if (nickname == plugin.state.bot.nickname) continue;

        plugin.updateUser(nickname);
    }
}


// onEndOfList
/++
 +  At the end of a long listing f users in a channel, when we're reasonably
 +  sure we've added users to our associative array of seen users, rehash it.
 +
 +  Rehashing optimises lookup and makes sense after you've added a big amount
 +  of entries.
 +/
@(IRCEvent.Type.RPL_ENDOFNAMES)
@(IRCEvent.Type.RPL_ENDOFWHO)
@(ChannelPolicy.homeOnly)
void onEndOfList(SeenPlugin plugin)
{
    plugin.seenUsers.rehash();
}


// onPing
/++
 +  Save seen files to disk with a periodicity of `hoursBetweenSaves` hours.
 +
 +  If we ride the periodicity of `PING` (which is sent to us every few minutes)
 +  we can just keep track of when we last saved, and save anew after the set
 +  number of hours have passed.
 +
 +  A new alternative to this would be to set up a timer `Fiber`, to process
 +  once every n seconds. It would have to be placed elsewhere though, not in a
 +  UDA-annotated on-`IRCEvent` function. Someplace only run once, like `start`.
 +
 +  ------------
 +  Fiber fiber;
 +  enum secs = 3600 * seenSettings.hoursBetweenSaves;
 +
 +  void foo()
 +  {
 +      with (plugin)
 +      while (true)
 +      {
 +          seenUser.saveSeen(seenSettings.seenFile);
 +
 +          // The Fiber callback must re-add its own Fiber
 +          // Declare it so that it's visible from inside here
 +          fiber.delayFiber(secs);
 +
 +          Fiber.yield();
 +      }
 +  }
 +
 +  fiber = new Fiber(&foo);
 +  fiber.call();  // trigger once immediately and let it queue itelf
 +  ------------
 +/
@(IRCEvent.Type.PING)
void onPing(SeenPlugin plugin)
{
    with (plugin)
    {
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
 +  The `BotCommand` annotation defines a piece of text that the incoming
 +  message must start with for this function to be called. `NickPolicy` deals
 +  with whether the message has to start with the name of the *bot* or not, and
 +  to what extent.
 +
 +  It can be one of:
 +  * `optional`, where the bot's nickname will be allowed and stripped away,
 +     but the function will still be invoked given the right command string.
 +  * `required`, where the message has to start with the name of the bot if in
 +     a `CHAN` message, but it needn't be there in a `QUERY`.
 +  * `hardRequired`, where the message *has* to start with the bot's nickname
 +     at all times, or this function will not be called.
 +  * `direct`, where the raw command is expected without any bot prefix at all.
 +
 +  The `IRCEvent` will probably look something like this:
 +
 +  --------------
 +  event.type = IRCEvent.Type.CHAN;
 +  event.sender.nickname = "foo";
 +  event.sender.ident = "~bar";
 +  event.sender.address = "baz.foo.bar.org";
 +  event.channel = "#bar";
 +  event.content = "Joe";
 +  --------------
 +
 +  The plugin system will have made certain we only get messages starting with
 +  "`seen`", since we annotated this function with such a `BotCommand`. It will
 +  since have been sliced off, so we're left only with the "arguments" to
 +  "`seen`".
 +
 +  If this is a `CHAN` event, the original lines was probably
 +  "`kameloso: seen Joe`". If it was a `QUERY`, the `kameloso:` prefix may have
 +  been omitted. In either case, we're left with only the parts we're
 +  interested in, and the rest sliced off.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.friend)
@(ChannelPolicy.homeOnly)
@BotCommand("seen")
@BotCommand(NickPolicy.required, "seen")
@Description("Queries the bot when it last saw a specified nickname online.")
void onCommandSeen(SeenPlugin plugin, const IRCEvent event)
{
    import kameloso.string : timeSince;
    import std.concurrency : send;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    if (event.sender.nickname == event.content)
    {
        /++
         +  The bot uses concurrency messages to queue strings to be sent to the
         +  server. This has benefits such as that even a multi-threaded program
         +  will have synchronous messages sent, and it's overall an easy and
         +  convenient way for plugin to send messages up the stack.
         +
         +  Future work may change this.
         +
         +  There are shorthand versions for sending these messages in
         +  `kameloso.messaging`, and this module has *mixed in* a template to
         +  create even shorter shorthand versions of them in the `SeenPlugin`.
         +  As such, you can use them as if they were member functions of it.
         +
         +  ------------
         +  with (plugin)
         +  {
         +      chan("#d", "Hello world!");
         +      query("kameloso", "Hello you!");
         +      privmsg(event.channel, event.sender.nickname, "Query or chan!");
         +      join("#flerrp");
         +      part("#flerrp");
         +      topic("#flerrp", "This is a new topic");
         +  }
         +  ------------
         +
         +  privmsg will either send a channel message or a personal query
         +  message depending on the arguments passed to it. If the first
         +  `channel` argument is not empty, it will be a channel message, else
         +  a query.
         +/
        // The person is asking for seen information about him-/herself.
        plugin.privmsg(event.channel, event.sender.nickname, "That's you!");
        return;
    }

    const userTimestamp = event.content in plugin.seenUsers;

    if (!userTimestamp)
    {
        // No matches for nickname `event.content` in `plugin.seenUsers`.

        plugin.privmsg(event.channel, event.sender.nickname,
            "I have never seen %s.".format(event.content));
        return;
    }

    const timestamp = SysTime.fromUnixTime(*userTimestamp);
    immutable elapsed = timeSince(Clock.currTime - timestamp);

    plugin.privmsg(event.channel, event.sender.nickname,
        "I last saw %s %s ago.".format(event.content, elapsed));
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
@(PrivilegeLevel.master)
@(ChannelPolicy.homeOnly)
@BotCommand(NickPolicy.required, "printseen")
@Description("[debug] Prints all seen users (and timestamps) to the local terminal.")
void onCommandPrintSeen(SeenPlugin plugin)
{
    import std.json : JSONValue;

    writeln(JSONValue(plugin.seenUsers).toPrettyString);
    version(Cygwin_) stdout.flush();
}


// updateUser
/++
 +  Update a given nickname's entry in the `JSON` seen storage with the current
 +  time, expressed in UNIX time.
 +
 +  This is not annotated with an IRC event type and will merely be invoked from
 +  elsewhere, like any normal function.
 +/
void updateUser(SeenPlugin plugin, const string signedNickname)
{
    import kameloso.irc : stripModesign;
    import std.algorithm.searching : canFind;
    import std.datetime.systime : Clock;

    with (plugin.state)
    {
        /// Make sure to strip the modesign, so `@foo` is the same person as `foo`.
        string nickname = signedNickname;
        bot.server.stripModesign(nickname);

        // Only update the user if he/she is in a home channel.
        foreach (homechan; bot.homes)
        {
            assert((homechan in channels), "Home channel " ~ homechan ~
                " was not in channels!");

            if (channels[homechan].users.canFind(nickname))
            {
                plugin.seenUsers[nickname] = Clock.currTime.toUnixTime;
                return;
            }
        }
    }
}


// loadSeen
/++
 +  Given a filename, read the contents and load it into a `long[string]`
 +  associative array, and return it. If there was no file there to read, return
 +  an empty array.
 +/
long[string] loadSeen(const string filename)
{
    import std.file   : exists, isFile, readText;
    import std.json   : parseJSON;

    long[string] aa;

    scope(exit)
    {
        logger.logf("Seen users loaded, currently %s users seen.", aa.length);
    }

    if (!filename.exists || !filename.isFile)
    {
        logger.info(filename, " does not exist or is not a file");
        return aa;
    }

    const asJSON = parseJSON(filename.readText).object;

    // Manually insert each entry from the JSON file into the long[string] AA.
    foreach (user, time; asJSON)
    {
        aa[user] = time.integer;
    }

    return aa;
}


// saveSeen
/++
 +  Saves the passed seen users associative array to disk, in `JSON` format.
 +/
void saveSeen(const long[string] seenUsers, const string filename)
{
    writeln("saving");
    auto file = File(filename, "w");

    file.write(JSONValue(seenUsers).toPrettyString);
    writeln(JSONValue(seenUsers).toPrettyString);
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
        seenUsers = loadSeen(seenSettings.seenFile);

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
 +  `UserAwareness` is a *mixin template*; a few functions defined in
 +  `kameloso.plugins.common` to deal with common bookkeeping that every plugin
 +  that wants to keep track of users need. If you don't want to track which
 +  users are in which channels, you don't need this.
 +/
mixin UserAwareness;


/++
 +  Complementary to `UserAwareness` is `ChannelAwareness`, which will add in
 +  bookkeeping about the channels the bot is in, their topics, modes and list
 +  of participants. Channel awareness requires user awareness, but not the
 +  other way around.
 +
 +  We will want it to limit the amount of tracked users to people in our home
 +  channels.
 +/
mixin ChannelAwareness;


/++
 +  Finally, our public bits.
 +/
public:


// SeenPlugin
/++
 +  This is your plugin to the outside world, the only thing visible in the
 +  entire module. It only serves as a way of proxying calls to our top-level
 +  private functions, as well as to house plugin-private variables that we want
 +  to keep out of top-level scope for the sake of modularity. If the only state
 +  is in the plugin, several plugins of the same kind can technically be run
 +  alongide eachother, which would allow for several bots to be run in
 +  parallel. This is not yet supported but there's nothing stopping it.
 +
 +  As such it houses this plugin's *state*, notably its instance of
 +  `SeenSettings` and its `IRCPluginState`.
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
 +     indirectly used it to send strings to the server by way of concurrency
 +     messages, but it is usually not something you will have to deal with
 +     directly.
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
     +
     +  This settings variable can be at top-level scope, but it can be
     +  considered good practice to keep it nested here. The entire
     +  `SeenSettings` struct can be placed here too, for that matter.
     +/
    @Settings SeenSettings seenSettings;

    /++
     +  The next hour we should save to disk. We set it up to do it
     +  occasionally, once every `seenSettings.hoursBetweenSaves`. See the
     +  definition of `SeenSettings`.
     +/
    uint nextHour;

    /++
     +  Our associative array (AA) of seen users; a dictionary keyed with users'
     +  nicknames and with values that are UNIX timetamps, denoting when that
     +  user was last seen.
     +
     +  --------------
     +  seenUsers["joe"] = Clock.currTime.toUnixTime;
     +  auto now = Clock.currTime.toUnixTime;
     +  writeln("Seconds since we last saw joe: ", (now - seenUsers["joe"]));
     +  --------------
     +/
    long[string] seenUsers;

    /++
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

    /++
     +  Our final mixin. This adds in functions to proxy calls to
     +  `kameloso.messaging` functions, *curried* with the main thread ID, so
     +  they can easily be called with knowledge only of the plugin symbol.
     +
     +  ------------
     +  plugin.chan("#d", "Hello world!");
     +  plugin.query("kameloso", "Hello you!");
     +  with (plugin)
     +  {
     +      chan("#d", "This is convenient");
     +      query("kameloso", "No need to specify plugin.state.mainThread");
     +  }
     +  ------------
     +/
    mixin MessagingProxy;
}

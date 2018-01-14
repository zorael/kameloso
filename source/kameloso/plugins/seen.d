/++
 +  This is an example plugin.
 +
 +  We will be writing a plugin with `seen` functionality; the ability for
 +  someone to query when a given nickname was last seen online.
 +
 +  We will implement this by keeping an internal `long[string]` asociative
 +  array of timestamps keyed by nickname. Whenever we see a user do something,
 +  we will update his or her timestamp with the current time. We'll save this
 +  array to disk when closing the program and read it from file when starting
 +  it, as well as occasionally once every few (configurable) hours.
 +
 +  We will rely on the `ChanQueriesPlugin` (in `chanqueries.d`) to query
 +  channels for full lists of users upon joining new channels, including the
 +  ones we join upon connecting. Elsewise, a completely silent user will never
 +  be recorded as having been seen, as they would never be triggering any of
 +  the functions we define to listen to.
 +
 +  kameloso does primarily not use callbacks, but instead annotates functions
 +  with `UDA`s of IRC event *types*. When an event is incoming it will trigger
 +  the function(s) annotated with its type.
 +
 +  Callback `Fiber`s *are* supported but are not in any large-scale use. They
 +  can be registered to process on incoming events, or timed with a worst-case
 +  precision of roughly `kameloso.constants.Timeout.receive` *
 +  `(kameloso.main.mainLoop).checkTimedFibersEveryN` + 1 seconds. Compared to
 +  using `IRCEvent` triggers they are expensive, in a micro-optimiing sense.
 +/

module kameloso.plugins.seen;

/// We need crucial things from `kameloso.plugins.common`.
import kameloso.plugins.common;

/// Likewise `kameloso.ircdefs`, for the definitions of an IRC event.
import kameloso.ircdefs;

/// `kameloso.common` for the instance of the *logger*, for terminal output.
import kameloso.common : logger;

/++
 +  Most of the module can (and ideally should) be kept private. Our surface
 +  area here will be restricted to only one `IRCPlugin` class, and the usual
 +  pattern used is to have the private bits first and that public class last.
 +  We'll turn that around here to make it easier to parse.
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
 +  make up the plugin's state. This is where information is kept about the bot,
 +  the server, and some metathings allowing us to send messages to the server.
 +  We don't define it here; we mix it in later with the `IRCPluginImpl` mixin.
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
 +     address, ident, and services account name. This is a way to keep track of
 +     users by more than merely their name. It is however not saved at the end
 +     of the program; it is merely state and transient.
 +
 +  * `whoisQueue` is also an associative array into which we place
 +    `WHOISRequest`s. The main loop will pick up on these and call `WHOIS` on
 +     the nickname in the key. A `WHOISRequest` is otherwise just an `IRCEvent`
 +     to be played back when the `WHOIS` results return, as well as a function
 +     pointer to call with that event. This is all wrapped in a function
 +     `doWhois`, with the queue management handled behind the scenes.
 +/
final class SeenPlugin : IRCPlugin
{
    // seenSetting
    /++
     +  An instance of *settings* for the Seen plugin. We will define this
     +  later. The members of it will be saved to and loaded from the
     +  configuration file, for use in our module. We need to annotate it
     +  `@Settings` to ensure it ends up there. The wizardry will pick it up.
     +
     +  This settings variable can be at top-level scope, but it can be
     +  considered good practice to keep it nested here. The entire
     +  `SeenSettings` struct definition can be placed here too, for that
     +  matter.
     +/
    @Settings SeenSettings seenSettings;


    // nextHour
    /++
     +  The next hour we should save to disk, a number from 0 to 23. We will set
     +  it up to save occasionally, once every few hours, as defined in one of
     +  the members of `SeenSettings` (`hoursBetweenSaves`).
     +/
    uint nextHour;

    // seenUsers
    /++
     +  Our associative array (AA) of seen users; the dictionary keyed with
     +  users' nicknames and with values that are UNIX timetamps, denoting when
     +  that user was last *seen* online.
     +
     +  --------------
     +  seenUsers["joe"] = Clock.currTime.toUnixTime;
     +  auto now = Clock.currTime.toUnixTime;
     +  writeln("Seconds since we last saw joe: ", (now - seenUsers["joe"]));
     +  --------------
     +/
    long[string] seenUsers;


    // mixin IRCPluginImpl
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


    // mixin MessagingProxy
    /++
     +  This mixin adds shorthand functions to proxy calls to
     +  `kameloso.messaging` functions, *curried* with the main thread ID, so
     +  they can easily be called with knowledge only of the plugin symbol.
     +
     +  ------------
     +  plugin.chan("#d", "Hello world!");
     +  plugin.query("kameloso", "Hello you!");
     +
     +  with (plugin)
     +  {
     +      chan("#d", "This is convenient");
     +      query("kameloso", "No need to specify plugin.state.mainThread");
     +  }
     +  ------------
     +/
    mixin MessagingProxy;
}


/++
 +  The rest will be private.
 +/
private:


// SeenSettings
/++
 +  We want our plugin to be *configurable* with a section for itself in the
 +  configuration file. For this purpose we create a "Settings" struct housing
 +  our configurable bits, which we already made an instance of in `SeenPlugin`.
 +
 +  If the name ends with "Settings", that will be stripped from its section
 +  header in the file. Hence, this plugin's `SeenSettings` will get the header
 +  `[Seen]`.
 +
 +  Each member of the struct will be given its own line in there. Note that not
 +  all types are supported, such as associative arrays or nested
 +  structs/classes.
 +/
struct SeenSettings
{
    /// How often to save seen users to disk (aside from program exit).
    int hoursBetweenSaves = 6;


    // seenFile
    /+
     +  The filename to which to persistently store our list of seen users
     +  between executions of the program.
     +/
    string seenFile = "seen.conf";
}


// onSomeAction
/++
 +  Whenever a user does something, record this user as having been seen at the
 +  current time.
 +
 +  This function will be called whenever an `IRCEvent` is being processed of
 +  the `IRCEvent.Type`s that we annotate the function with.
 +
 +  The `Chainable` annotations mean that the plugin will also process other
 +  functions with the same `IRCEvent.Type` annotations, even if this one
 +  matched. The default is otherwise that it will end early after one match,
 +  but this doesn't ring well with catch-all functions like these. It's
 +  sensible to save `Chainable` for the functions that actually need it.
 +
 +  The `ChannelPolicy` annotation decides whether this function should be
 +  called based on the *channel* the event took place in, if applicable.
 +  The two policies are `home`, in which only events in channels in the `homes`
 +  array will be allowed to trigger this; or `any`, in which case anywhere
 +  goes.
 +
 +  Not all events relate to a particular channel, such as `QUIT` (quitting
 +  leaves every channel).
 +
 +  The `PrivilegeLevel` annotation dictates who is authorised to trigger the
 +  function. It has three policies; `anyone`, `whitelist` and `admin`.
 +
 +  * `anyone` will let precisely anyone trigger it, without looking them up.
 +  * `whitelist will only allow users in the `whitelist` array in the
 +     configuration file.
 +  * `admin` will allow only you and your other adminitrators, also as defined
 +     in the configuration file.
 +
 +  In the case of `whitelist` and `admin`, it will look you up and compare your
 +  *services account name* to those configured before doing anything. If you
 +  aren't logged into services, or if your account name isn't included in the
 +  lists, the function will not trigger.
 +
 +  This particular function doesn't care.
 +/
@(Chainable)
@(IRCEvent.Type.EMOTE)
@(IRCEvent.Type.QUERY)
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.JOIN)
@(IRCEvent.Type.PART)
@(IRCEvent.Type.QUIT)
@(PrivilegeLevel.anyone)
@(ChannelPolicy.home)
void onSomeAction(SeenPlugin plugin, const IRCEvent event)
{
    /++
     +  Update the user's timestamp to the current time.
     +
     +  This will, as such, be automatically called on `EMOTE`, `QUERY`, `CHAN`,
     +  `JOIN`, `PART` and `QUIT` events. Furthermore, it will only trigger if
     +  it took place in a home channel, in the case of all but `QUIT` (which
     +  as noted is global and not associated with a channel).
     +
     +  It says `plugin.updateUser(...)` but there is no method `updateUser` in
     +  the `SeenPlugin plugin`; it is top-/module-level. Virtually the entirety
     +  of our implementation will rely on UFCS.
     +/
    plugin.updateUser(event.sender.nickname);
}


// onNick
/++
 +  When someone changes nickname, move the old seen timestamp to a new entry
 +  for the new nickname, and remove the old one.
 +
 +  Bookkeeping; this is to avoid getting ghost entries in the seen array.
 +/
@(Chainable)
@(IRCEvent.Type.NICK)
@(PrivilegeLevel.anyone)
void onNick(SeenPlugin plugin, const IRCEvent event)
{
    /++
     +  There may not be an old one if the user was not indexed upon us joinng
     +  the channel, which is the case with `ChannelPolicy.home` and non-home
     +  channels. If there is no entry that means nothing channel-aware has
     +  added it, which implies that it's not in a home channel. Ignore it if
     +  so.
     +/

    if (auto user = event.sender.nickname in plugin.seenUsers)
    {
        plugin.seenUsers[event.target.nickname] = *user;
        plugin.seenUsers.remove(event.sender.nickname);
    }
}


// onWHOReply
/++
 +  Catch each user listed in a `WHO` reply and update their entries in the seen
 +  users list, creating them if they don't exist.
 +
 +  A `WHO` request enumerates all members in a channel. It returns several
 +  replies, one event per each user in the channel. The *ChannelQueries* plugin
 +  instigates this shortly after having joined one, as a service to the other
 +  plugins.
 +/
@(IRCEvent.Type.RPL_WHOREPLY)
@(ChannelPolicy.home)
void onWHOReply(SeenPlugin plugin, const IRCEvent event)
{
    /// Update the user's entry
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
@(ChannelPolicy.home)
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
 +  At the end of a long listing of users in a channel, when we're reasonably
 +  sure we've added users to our associative array of seen users, *rehash* it.
 +
 +  Rehashing optimises lookup and makes sense after we've added a big amount of
 +  entries.
 +/
@(IRCEvent.Type.RPL_ENDOFNAMES)
@(IRCEvent.Type.RPL_ENDOFWHO)
@(ChannelPolicy.home)
void onEndOfList(SeenPlugin plugin)
{
    plugin.seenUsers.rehash();
}


// onPing
/++
 +  Save seen files to disk once every `hoursBetweenSaves` hours.
 +
 +  If we ride the periodicity of `PING` (which is sent to us every few minutes)
 +  we can just keep track of when we last saved, and save anew after the set
 +  number of hours have passed.
 +
 +  An alternative to this would be to set up a timer `Fiber`, to process once
 +  every n seconds. It would have to be placed elsewhere though, not in a UDA-
 +  annotated on-`IRCEvent` function. Someplace only run once, like `start`, or
 +  at the end of the message of the day (event type `RPL_ENDOFMOTD`).
 +
 +  ------------
 +  // The Fiber delegate must re-add its own Fiber
 +  // Declare it here before so it's visible from inide it
 +  Fiber fiber;
 +  enum secs = 3600 * seenSettings.hoursBetweenSaves;
 +
 +  void foo()
 +  {
 +      with (plugin)
 +      while (true)
 +      {
 +          seenUser.saveSeen(seenSettings.seenFile);
 +          fiber.delayFiber(secs);  // <-- needs visibility of fiber
 +          Fiber.yield();
 +      }
 +  }
 +
 +  fiber = new Fiber(&foo);
 +  fiber.call();  // trigger once immediately and let it queue itelf
 +  ------------
 +
 +  Mind that this approach is more expensive than relying on `PING`, as it
 +  incurs lots of associative array lookups.
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
            seenUsers.rehash().saveSeen(seenSettings.seenFile);
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
 +  Nickname policies can be one of:
 +  * `optional`, where the bot's nickname will be allowed and stripped away,
 +     but the function will still be invoked given the right command string.
 +  * `required`, where the message has to start with the name of the bot if in
 +     a `CHAN` message, but it needn't be there in a `QUERY`.
 +  * `hardRequired`, where the message *has* to start with the bot's nickname
 +     at all times, or this function will not be called.
 +  * `direct`, where the raw command is expected without any bot prefix at all.
 +
 +  The plugin system will have made certain we only get messages starting with
 +  "`seen`", since we annotated this function with such a `BotCommand`. It will
 +  since have been sliced off, so we're left only with the "arguments" to
 +  "`seen`".
 +
 +  If this is a `CHAN` event, the original lines could (for example) have been
 +  "`kameloso: seen Joe`", or merely "`!seen Joe`" (asuming a `!` prefix).
 +  If it was a private `QUERY` message, the `kameloso:` prefix may have been
 +  omitted. In either case, we're left with only the parts we're interested in,
 +  and the rest sliced off.
 +
 +  As a result, the `IRCEvent` would look something like this:
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
 +  Lastly, the `Description` annotation merely defines how this function will
 +  be listed in the "online help" list, shown by sending "`help`" to the bot in
 +  a private message.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.whitelist)
@(ChannelPolicy.home)
@BotCommand("seen")
@BotCommand(NickPolicy.required, "seen")
@Description("Queries the bot when it last saw a specified nickname online.")
void onCommandSeen(SeenPlugin plugin, const IRCEvent event)
{
    import kameloso.string : has, timeSince;
    import std.algorithm : canFind;
    import std.concurrency : send;
    import std.datetime.systime : Clock, SysTime;
    import std.format : format;

    /++
     +  The bot uses concurrency messages to queue strings to be sent to the
     +  server. This has benefits such as that even a multi-threaded program
     +  will have synchronous messages sent, and it's overall an easy and
     +  convenient way for plugin to send messages up the stack.
     +
     +  There are shorthand versions for sending these messages in
     +  `kameloso.messaging`, and additionally this module has mixed in
     +  `MessagingProxy` in the `SeenPlugin`, creating even shorter shorthand
     +  versions.
     +
     +  You can therefore use them as such:
     +
     +  ------------
     +  with (plugin)  // <-- neccessary for the short-shorthand
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
     +  `privmsg` will either send a channel message or a personal query message
     +  depending on the arguments passed to it. If the first `channel` argument
     +  is not empty, it will be a `chan` channel message, else a private
     +  `query` message.
     +/

    with (plugin)
    {
        if (!event.content.length)
        {
            // No nickname supplied...
            return;
        }
        else if (event.content.has!(Yes.decode)(" "))
        {
            // Nickname contained a space
            privmsg(event.channel, event.sender.nickname, "Invalid user: " ~
                event.content);
            return;
        }
        else if (event.sender.nickname == event.content)
        {
            // The person is asking for seen information about him-/herself.
            privmsg(event.channel, event.sender.nickname, "That's you!");
            return;
        }
        else if (event.channel.length && state.channels[event.channel].users
            .canFind(event.content))
        {
            // Channel message and the user is in the channel
            chan(event.channel, event.content ~ " is here right now!");
        }

        const userTimestamp = event.content in seenUsers;

        if (!userTimestamp)
        {
            // No matches for nickname `event.content` in `plugin.seenUsers`.
            privmsg(event.channel, event.sender.nickname,
                "I have never seen %s.".format(event.content));
            return;
        }

        const timestamp = SysTime.fromUnixTime(*userTimestamp);
        immutable elapsed = timeSince(Clock.currTime - timestamp);

        privmsg(event.channel, event.sender.nickname,
            "I last saw %s %s ago.".format(event.content, elapsed));
    }
}


// onCommandPrintSeen
/++
 +  As a tool to help debug, print the current `seenUsers` associative array to
 +  the local terminal.
 +/
@(IRCEvent.Type.CHAN)
@(IRCEvent.Type.QUERY)
@(PrivilegeLevel.admin)
@(ChannelPolicy.home)
@BotCommand(NickPolicy.required, "printseen")
@Description("[debug] Prints all seen users (and timestamps) to the local terminal.")
void onCommandPrintSeen(SeenPlugin plugin)
{
    import std.json : JSONValue;
    import std.stdio : stdout, writeln;

    writeln(JSONValue(plugin.seenUsers).toPrettyString);
    version(Cygwin_) stdout.flush();
}


// updateUser
/++
 +  Update a given nickname's entry in the seen array with the current time,
 +  expressed in UNIX time.
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
        /// Make sure to strip the modesign, so `@foo` is the same person as
        // `foo`.
        string nickname = signedNickname;
        bot.server.stripModesign(nickname);

        // Only update the user if he/she is in a home channel.
        foreach (homechan; bot.homes)
        {
            assert((homechan in channels), "Home channel " ~ homechan ~
                " was not in channels! Channel awareness should have added it.");

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
 +  associative array, then return it. If there was no file there to read,
 +  return an empty array for a fresh start.
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

    // Rehash the AA, since we potentially added a *lot* of users.
    return aa.rehash();
}


// saveSeen
/++
 +  Saves the passed seen users associative array to disk, but in `JSON` format.
 +
 +  This is a convenient way to serialise the array.
 +/
void saveSeen(const long[string] seenUsers, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, write, writeln;

    auto file = File(filename, "w");

    file.write(JSONValue(seenUsers).toPrettyString);
    file.writeln();
}


// onEndOfMotd
/++
 +  After we have registered on the server and seen the "message of the day"
 +  spam, load our seen users from file.`
 +
 +  At the same time, zero out the periodic save schedule, so that the next
 +  save will be in `hoursBetweenSaves` hours from now. See `onPing` for
 +  details.
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
 +  array to disk for later reloading.
 +/
void teardown(IRCPlugin basePlugin)
{
    SeenPlugin plugin = cast(SeenPlugin)basePlugin;
    plugin.seenUsers.saveSeen(plugin.seenSettings.seenFile);
}


/++
 +  `UserAwareness` is a mixin template; a few functions defined in
 +  `kameloso.plugins.common` to deal with common bookkeeping that every plugin
 +  *that wants to keep track of users* need. If you don't want to track which
 +  users you have seen (and are visible to you now), you don't need this.
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
 +  This full plugin is 104 source lines of code. (`dscanner --sloc seen.d`)
 +/

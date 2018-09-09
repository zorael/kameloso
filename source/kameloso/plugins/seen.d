/++
 +  The Seen plugin implements `seen` functionality; the ability for someone to
 +  query when a given nickname was last seen online.
 +
 +  We will implement this by keeping an internal `long[string]` associative
 +  array of timestamps keyed by nickname. Whenever we see a user do something,
 +  we will update his or her timestamp to the current time. We'll save this
 +  array to disk when closing the program and read it from file when starting
 +  it, as well as saving occasionally once every few (configurable) hours.
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
 +  Callback `core.thread.Fiber`s *are* supported but are not in any large-scale
 +  use. They can be registered to process on incoming events, or timed with a
 +  worst-case precision of roughly `kameloso.constants.Timeout.receive` *
 +  `(kameloso.main.mainLoop).checkTimedFibersEveryN` + 1 seconds. Compared to
 +  using `kameloso.ircdefs.IRCEvent` triggers they are expensive, in a
 +  micro-optimising sense.
 +/

module kameloso.plugins.seen;

/// We need crucial things from `kameloso.plugins.common`.
import kameloso.plugins.common;

/// Likewise `kameloso.ircdefs`, for the definitions of an IRC event.
import kameloso.ircdefs;

/// `kameloso.common` for some globals.
import kameloso.common;

/+
 +  Most of the module can (and ideally should) be kept private. Our surface
 +  area here will be restricted to only one `kameloso.plugins.common.IRCPlugin`
 +  class, and the usual pattern used is to have the private bits first and that
 +  public class last. We'll turn that around here to make it easier to parse.
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
 +  `SeenSettings` and its `kameloso.plugins.common.IRCPluginState`.
 +
 +  The `kameloso.plugins.common.IRCPluginState` is a struct housing various
 +  variables that together make up the plugin's state. This is where
 +  information is kept about the bot, the server, and some metathings allowing
 +  us to send messages to the server. We don't define it here; we mix it in
 +  later with the `kameloso.plugins.common.IRCPluginImpl` mixin.
 +
 +  ---
 +  struct IRCPluginState
 +  {
 +      IRCBot bot;
 +      CoreSettings settings;
 +      Tid mainThread;
 +      IRCUser[string] users;
 +      IRCChannel[string] channels;
 +      WHOISRequest[string] whoisQueue;
 +  }
 +  ---
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
 +     that key is an `kameloso.ircdefs.IRCUser` representing that user in terms
 +     of nickname, address, ident, and services account name. This is a way to
 +     keep track of users by more than merely their name. It is however not
 +     saved at the end of the program; it is merely state and transient.
 +
 +  * `channels` is another associative array, this one with all the known
 +     channels keyed by their names. This way we can access detailed
 +     information about any given channel, knowing only their name.
 +
 +  * `whoisQueue` is also an associative array into which we place
 +    `kameloso.plugins.common.WHOISRequest`s. The main loop will pick up on
 +     these and call `WHOIS` on the nickname in the key. A
 +     `kameloso.plugins.common.WHOISRequest` is otherwise just an
 +     `kameloso.ircdefs.IRCEvent` to be played back when the `WHOIS` results
 +     return, as well as a function pointer to call with that event. This is
 +     all wrapped in a function `kameloso.plugins.common.doWhois`, with the
 +     queue management handled behind the scenes.
 +/
final class SeenPlugin : IRCPlugin
{
    // seenSetting
    /++
     +  An instance of *settings* for the Seen plugin. We will define this
     +  later. The members of it will be saved to and loaded from the
     +  configuration file, for use in our module. We need to annotate it
     +  `@Settings` to ensure it ends up there, and the wizardry will pick it
     +  up.
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
     +  ---
     +  seenUsers["joe"] = Clock.currTime.toUnixTime;
     +  auto now = Clock.currTime.toUnixTime;
     +  writeln("Seconds since we last saw joe: ", (now - seenUsers["joe"]));
     +  ---
     +/
    long[string] seenUsers;


    // seenFile
    /+
     +  The filename to which to persistently store our list of seen users
     +  between executions of the program.
     +
     +  This is only the basename of the file. It will be completed with a path
     +  to the default (or specified) resource directory, which varies by
     +  platform. Expect this variable to have values like
     +  "/home/user/.local/share/kameloso/servers/irc.freenode.net/seen.json"
     +  after the plugin has been instantiated.
     +/
    @ResourceFile string seenFile = "seen.json";


    // mixin IRCPluginImpl
    /++
     +  This mixes in functions that fully implement an
     +  `kameloso.plugins.common.IRCPlugin`. They don't do much by themselves
     +  other than call the module's functions.
     +
     +  As an exception, it mixes in the bits needed to automatically call
     +  functions based on their `kameloso.ircdefs.IRCEvent.Type` annotations.
     +  It is mandatory, if you want things to work.
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
     +  ---
     +  plugin.chan("#d", "Hello world!");
     +  plugin.query("kameloso", "Hello you!");
     +
     +  with (plugin)
     +  {
     +      chan("#d", "This is convenient");
     +      query("kameloso", "No need to specify plugin.state.mainThread");
     +  }
     +  ---
     +/
    mixin MessagingProxy;
}


/+
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
    /// Toggles whether or not the plugin should react to events at all.
    bool enabled = true;

    /// How often to save seen users to disk (aside from program exit).
    int hoursBetweenSaves = 6;
}


// onSomeAction
/++
 +  Whenever a user does something, record this user as having been seen at the
 +  current time.
 +
 +  This function will be called whenever an `kameloso.ircdefs.IRCEvent` is
 +  being processed of the `kameloso.ircdefs.IRCEvent.Type`s that we annotate
 +  the function with.
 +
 +  The `kameloso.plugins.common.Chainable` annotations mean that the plugin
 +  will also process other functions in this module with the same
 +  `kameloso.ircdefs.IRCEvent.Type` annotations, even if this one matched. The
 +  default is otherwise that it will end early after one match, but this
 +  doesn't ring well with catch-all functions like these. It's sensible to save
 +  `kameloso.plugins.common.Chainable` for the modules and functions that
 +  actually need it.
 +
 +  The `kameloso.plugins.common.ChannelPolicy` annotation decides whether this
 +  function should be called based on the *channel* the event took place in, if
 +  applicable. The two policies are `home`, in which only events in channels in
 +  the `homes` array will be allowed to trigger this; or `any`, in which case
 +  anywhere goes. For events that don't correspond to a channel (such as
 +  `IRCEvent.Type.QUERY`) the setting is ignored.
 +
 +  Not all events relate to a particular channel, such as `QUIT` (quitting
 +  leaves every channel).
 +
 +  The `kameloso.plugins.common.PrivilegeLevel` annotation dictates who is
 +  authorised to trigger the function. It has three policies; `anyone`,
 +  `whitelist` and `admin`.
 +
 +  * `anyone` will let precisely anyone trigger it, without looking them up.
 +     <br>
 +  * `whitelist` will only allow users in the `whitelist` array in the
 +     configuration file.<br>
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
    if (!plugin.seenSettings.enabled) return;

    /++
     +  Updates the user's timestamp to the current time.
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
 +  When someone changes nickname, moves the old seen timestamp to a new entry
 +  for the new nickname, removing the old one.
 +
 +  Bookkeeping; this is to avoid getting ghost entries in the seen array.
 +/
@(Chainable)
@(IRCEvent.Type.NICK)
@(PrivilegeLevel.anyone)
void onNick(SeenPlugin plugin, const IRCEvent event)
{
    if (!plugin.seenSettings.enabled) return;

    /++
     +  There may not be an old one if the user was not indexed upon us joining
     +  the channel for some reason.
     +/

    if (auto user = event.sender.nickname in plugin.seenUsers)
    {
        plugin.seenUsers[event.target.nickname] = *user;
        plugin.seenUsers.remove(event.sender.nickname);
    }
}


// onWHOReply
/++
 +  Catches each user listed in a `WHO` reply and updates their entries in the
 +  seen users list, creating them if they don't exist.
 +
 +  A `WHO` request enumerates all members in a channel. It returns several
 +  replies, one event per each user in the channel. The
 +  `kameloso.plugins.chanqueries.ChanQueriesService` services instigates this
 +  shortly after having joined one, as a service to the other plugins.
 +/
@(IRCEvent.Type.RPL_WHOREPLY)
@(ChannelPolicy.home)
void onWHOReply(SeenPlugin plugin, const IRCEvent event)
{
    if (!plugin.seenSettings.enabled) return;

    // Update the user's entry
    plugin.updateUser(event.target.nickname);
}


/++
 +  Catch a `NAMES` reply and record each person as having been seen.
 +
 +  When requesting `NAMES` on a channel, the server will send a big list of
 +  every participant in it, in a big string of nicknames separated by spaces.
 +  This is done automatically when you join a channel. Nicknames are prefixed
 +  with mode signs if they are operators, voiced or similar, so we'll need to
 +  strip that away.
 +/
@(IRCEvent.Type.RPL_NAMREPLY)
@(ChannelPolicy.home)
void onNameReply(SeenPlugin plugin, const IRCEvent event)
{
    if (!plugin.seenSettings.enabled) return;

    import std.algorithm.iteration : splitter;

    /++
     +  Use a `std.algorithm.iteration.splitter` to iterate each name and call
     +  `updateUser` to update (or create) their entry in the `seenUsers`
     +  associative array.
     +/

    foreach (const signed; event.content.splitter(" "))
    {
        import kameloso.irc : stripModesign;
        import kameloso.string : contains, nom;

        string nickname = signed;

        if (nickname.contains('!'))
        {
            // SpotChat-like, signed is in full nick!ident@address form
            nickname = nickname.nom('!');
        }

        nickname = plugin.state.bot.server.stripModesign(nickname);
        if (nickname == plugin.state.bot.nickname) continue;

        plugin.updateUser(nickname);
    }
}


// onEndOfList
/++
 +  Optimises the lookups in the associative array of seen users.
 +
 +  At the end of a long listing of users in a channel, when we're reasonably
 +  sure we've added users to our associative array of seen users, *rehashes*
 +  it.
 +/
@(IRCEvent.Type.RPL_ENDOFNAMES)
@(IRCEvent.Type.RPL_ENDOFWHO)
@(ChannelPolicy.home)
void onEndOfList(SeenPlugin plugin)
{
    if (!plugin.seenSettings.enabled) return;

    plugin.seenUsers.rehash();
}


// onPing
/++
 +  Saves seen files to disk once every `hoursBetweenSaves` hours.
 +
 +  If we ride the periodicity of `PING` (which is sent to us every few minutes)
 +  we can just keep track of when we last saved, and save anew after the set
 +  number of hours have passed.
 +
 +  An alternative to this would be to set up a timer `core.thread.Fiber`, to
 +  process once every *n* seconds. It would have to be placed elsewhere though,
 +  not in a UDA-annotated on-`kameloso.ircdefs.IRCEvent` function. Someplace
 +  only run once, like `start`, or at the end of the message of the day (event
 +  type `RPL_ENDOFMOTD`).
 +
 +  ---
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
 +          seenUsers.saveSeen(seenFile);
 +          fiber.delayFiber(secs);  // <-- needs visibility of fiber
 +          Fiber.yield();
 +      }
 +  }
 +
 +  fiber = new Fiber(&foo);
 +  fiber.call();  // trigger once immediately and let it queue itelf
 +  ---
 +
 +  Mind that this approach is more expensive than relying on `PING`, as it
 +  incurs lots of array lookups. "Expensive" in a micro-optimising sense; it's
 +  still just array lookups.
 +/
@(IRCEvent.Type.PING)
void onPing(SeenPlugin plugin)
{
    if (!plugin.seenSettings.enabled) return;

    with (plugin)
    {
        import std.datetime.systime : Clock;

        immutable now = Clock.currTime;

        /// Once every n hours, save the JSON storage to disk.
        if ((seenSettings.hoursBetweenSaves > 0) && (now.hour == nextHour))
        {
            nextHour = (nextHour + seenSettings.hoursBetweenSaves) % 24;
            seenUsers.rehash().saveSeen(seenFile);
        }
    }
}


// onCommandSeen
/++
 +  Whenever someone says "seen" in a `CHAN` or a `QUERY`, and if `CHAN` then
 +  only if in a *home*, processes this function.
 +
 +  The `kameloso.plugins.common.BotCommand` annotation defines a piece of text
 +  that the incoming message must start with for this function to be called.
 +  `kameloso.plugins.common.NickPolicy` deals with whether the message has to
 +  start with the name of the *bot* or not, and to what extent.
 +
 +  Nickname policies can be one of:
 +  * `optional`, where the bot's nickname will be allowed and stripped away,
 +     but the function will still be invoked given the right command string.
 +     <br>
 +  * `required`, where the message has to start with the name of the bot if in
 +     a `CHAN` message, but it needn't be there in a `QUERY`.<br>
 +  * `hardRequired`, where the message *has* to start with the bot's nickname
 +     at all times, or this function will not be called.<br>
 +  * `direct`, where the raw command is expected without any bot prefix at all.
 +
 +  The plugin system will have made certain we only get messages starting with
 +  "`seen`", since we annotated this function with such a
 +  `kameloso.plugins.common.BotCommand`. It will ssince have been sliced off,
 +  so we're left only with the "arguments" to "`seen`".
 +
 +  If this is a `CHAN` event, the original lines could (for example) have been
 +  "`kameloso: seen Joe`", or merely "`!seen Joe`" (asuming a `!` prefix).
 +  If it was a private `QUERY` message, the `kameloso:` prefix may have been
 +  omitted. In either case, we're left with only the parts we're interested in,
 +  and the rest sliced off.
 +
 +  As a result, the `kameloso.ircdefs.IRCEvent` `event` would look something
 +  like this:
 +
 +  ---
 +  event.type = IRCEvent.Type.CHAN;
 +  event.sender.nickname = "foo";
 +  event.sender.ident = "~bar";
 +  event.sender.address = "baz.foo.bar.org";
 +  event.channel = "#bar";
 +  event.content = "Joe";
 +  ---
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
    if (!plugin.seenSettings.enabled) return;

    import kameloso.common : timeSince;
    import kameloso.irc : isValidNickname;
    import kameloso.string : contains;
    import std.algorithm.searching : canFind;
    import std.datetime.systime; //: Clock, SysTime;
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
     +  ---
     +  with (plugin)  // <-- neccessary for the short-shorthand
     +  {
     +      chan("#d", "Hello world!");
     +      query("kameloso", "Hello you!");
     +      privmsg(event.channel, event.sender.nickname, "Query or chan!");
     +      join("#flerrp");
     +      part("#flerrp");
     +      topic("#flerrp", "This is a new topic");
     +  }
     +  ---
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
        else if (!event.content.isValidNickname(plugin.state.bot.server))
        {
            // Nickname contained a space
            privmsg(event.channel, event.sender.nickname, "Invalid user: " ~ event.content);
            return;
        }
        else if (event.sender.nickname == event.content)
        {
            // The person is asking for seen information about him-/herself.
            privmsg(event.channel, event.sender.nickname, "That's you!");
            return;
        }
        else if (event.channel.length && state.channels[event.channel].users.canFind(event.content))
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
 +  As a tool to help debug, prints the current `seenUsers` associative array to
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
    if (!plugin.seenSettings.enabled) return;

    import std.json : JSONValue;
    import std.stdio : stdout, writeln;

    writeln(JSONValue(plugin.seenUsers).toPrettyString);
    version(Cygwin_) stdout.flush();
}


// updateUser
/++
 +  Updates a given nickname's entry in the seen array with the current time,
 +  expressed in UNIX time.
 +
 +  This is not annotated with an IRC event type and will merely be invoked from
 +  elsewhere, like any normal function.
 +
 +  Params:
 +      plugin = Current `SeenPlugin`.
 +      signedNickname = Nickname to update, potentially prefixed with a
 +          modesign (@, +, %, ...).
 +/
void updateUser(SeenPlugin plugin, const string signed)
{
    import kameloso.irc : stripModesign;
    import std.algorithm.searching : canFind;
    import std.datetime.systime : Clock;

    with (plugin.state)
    {
        /++
         +  Make sure to strip the modesign, so `@foo` is the same person as
         +  `foo`.
         +/
        immutable nickname = bot.server.stripModesign(signed);

        // Only update the user if he/she is in a home channel.
        foreach (homechan; bot.homes)
        {
            if (const channel = homechan in channels)
            {
                if (channel.users.canFind(nickname))
                {
                    plugin.seenUsers[nickname] = Clock.currTime.toUnixTime;
                    return;
                }
            }
        }
    }
}


// loadSeen
/++
 +  Given a filename, reads the contents and load it into a `long[string]`
 +  associative array, then returns it. If there was no file there to read,
 +  returns an empty array for a fresh start.
 +
 +  Params:
 +      plugin = The current `SeenPlugin`.
 +      filename = Filename of the file to read from.
 +
 +  Returns:
 +      `long[string]` associative array; UNIX timestamp longs keyed by nickname
 +          strings.
 +/
long[string] loadSeen(SeenPlugin plugin, const string filename)
{
    import std.file : exists, isFile, readText;
    import std.json : JSONException, parseJSON;

    long[string] aa;

    scope(exit)
    {
        string infotint, logtint;

        version(Colours)
        {
            if (!plugin.state.settings.monochrome)
            {
                import kameloso.bash : colour;
                import kameloso.logger : KamelosoLogger;
                import std.experimental.logger : LogLevel;

                infotint = KamelosoLogger.tint(LogLevel.info, settings.brightTerminal).colour;
                logtint = KamelosoLogger.tint(LogLevel.all, settings.brightTerminal).colour;
            }
        }

        logger.logf("Seen users loaded, currently %s%d%s users seen.",
            infotint, aa.length, logtint);
    }

    if (!filename.exists || !filename.isFile)
    {
        logger.info(filename, " does not exist or is not a file");
        return aa;
    }

    try
    {
        const asJSON = parseJSON(filename.readText).object;

        // Manually insert each entry from the JSON file into the long[string] AA.
        foreach (user, time; asJSON)
        {
            aa[user] = time.integer;
        }
    }
    catch (const JSONException e)
    {
        logger.error("Could not load seen JSON from file: ", e.msg);
    }

    // Rehash the AA, since we potentially added a *lot* of users.
    return aa.rehash();
}


// saveSeen
/++
 +  Saves the passed seen users associative array to disk, but in `JSON` format.
 +
 +  This is a convenient way to serialise the array.
 +
 +  Params:
 +      seenUsers = The associative array of seen users to save.
 +      filename = Filename of the file to write to.
 +/
void saveSeen(const long[string] seenUsers, const string filename)
{
    import std.json : JSONValue;
    import std.stdio : File, write, writeln;

    auto file = File(filename, "w");

    file.writeln(JSONValue(seenUsers).toPrettyString);
}


// onEndOfMotd
/++
 +  After we have registered on the server and seen the "message of the day"
 +  spam, loads our seen users from file.`
 +
 +  At the same time, zero out the periodic save schedule, so that the next
 +  save will be in `hoursBetweenSaves` hours from now. See `onPing` for
 +  details.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
@(IRCEvent.Type.ERR_NOMOTD)
void onEndOfMotd(SeenPlugin plugin)
{
    if (!plugin.seenSettings.enabled) return;

    with (plugin)
    {
        seenUsers = plugin.loadSeen(seenFile);

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
 +  When closing the program or when crashing with grace, saves the seen users
 +  array to disk for later reloading.
 +/
void teardown(SeenPlugin plugin)
{
    plugin.seenUsers.saveSeen(plugin.seenFile);
}


// initResources
/++
 +  Reads and writes the file of seen people to disk, ensuring that it's there.
 +/
void initResources(SeenPlugin plugin)
{
    import kameloso.json : JSONStorage;

    JSONStorage json;
    json.load(plugin.seenFile);
    json.save(plugin.seenFile);
}


/++
 +  `kameloso.plugins.common.UserAwareness` is a mixin template; a few functions
 +  defined in `kameloso.plugins.common` to deal with common bookkeeping that
 +  every plugin *that wants to keep track of users* need. If you don't want to
 +  track which users you have seen (and are visible to you now), you don't need
 +  this.
 +/
mixin UserAwareness;


/++
 +  Complementary to `kameloso.plugins.common.UserAwareness` is
 +  `kameloso.plugins.common.ChannelAwareness`, which will add in bookkeeping
 +  about the channels the bot is in, their topics, modes and list of
 +  participants. Channel awareness requires user awareness, but not the other
 +  way around.
 +
 +  We will want it to limit the amount of tracked users to people in our home
 +  channels.
 +/
mixin ChannelAwareness;


/++
 +  This full plugin is 146 source lines of code. (`dscanner --sloc seen.d`)
 +/

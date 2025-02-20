/++
    Functions for generating a Twitch API key.

    See_Also:
        [kameloso.plugins.twitch],
        [kameloso.plugins.twitch.api],
        [kameloso.plugins.twitch.providers.common],
        [kameloso.plugins]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.providers.twitch;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch;
import kameloso.plugins.twitch.common;
import kameloso.plugins.twitch.providers.common;
import kameloso.common : logger;
import kameloso.terminal.colours.tags : expandTags;
import core.thread.fiber : Fiber;

public:


/+
These were hand-copy/pasted from the Twitch API reference page.

    https://dev.twitch.tv/docs/api/reference

Some endpoints may be missing or incorrect but I tried my best.


# BROADCASTER/OWN USER ONLY

start commercial                channel:edit:commercial
get ad schedule                 channel:read:ads
snooze next ad                  channel:manage:broadcast
modify channel information      channel:manage:broadcast
get channel editors             channel:read:editors
delete custom rewards           channel:manage:redemptions
update redemption status        channel:manage:redemptions
get charity campaign            channel:read:charity
get charity campaign donations  channel:read:charity
get creator goals               channel:read:goals
get channel guest star settings channel:read:guest_star channel:manage:guest_star moderator:read:guest_star moderator:manage:guest_star
get guest star session          channel:read:guest_star channel:manage:guest_star moderator:read:guest_star moderator:manage:guest_star
get guest star invites          channel:read:guest_star channel:manage:guest_star moderator:read:guest_star moderator:manage:guest_star
update guest star settings      channel:manage:guest_star
create guest star session       channel:manage:guest_star
end guest star session          channel:manage:guest_star
send guest star invite          moderator:manage:guest_star channel:manage:guest_star
delete guest star invite        moderator:manage:guest_star channel:manage:guest_star
assign guest star slot          moderator:manage:guest_star channel:manage:guest_star
update guest star slot          moderator:manage:guest_star channel:manage:guest_star
update guest star slot settings moderator:manage:guest_star channel:manage:guest_star
get hype train events           channel:read:hype_train
get moderators                  moderation:read channel:manage:moderators
add channel moderator           channel:manage:moderators
remove channel moderator        channel:manage:moderators
get VIPs                        channel:read:vips channel:manage:vips
add channel VIP                 channel:manage:vips
remove channel VIP              channel:manage:vips
get predictions                 channel:read:predictions channel:manage:predictions
create predictions              channel:manage:predictions
end predictions                 channel:manage:predictions
start a raid                    channel:manage:raids
cancel a raid                   channel:manage:raids
update channel stream schedule  channel:manage:schedule
create stream schedule segment  channel:manage:schedule
update stream schedule segment  channel:manage:schedule
delete stream schedule segment  channel:manage:schedule
get stream key                  channel:read:stream_key
create stream marker            channel:manage:broadcast
get stream markers              user:read:broadcast channel:manage:broadcast
get broadcaster subscriptions   channel:read:subscriptions
get user block list             user:read:blocked_users
get polls                       channel:read:polls channel:manage:polls
create poll                     channel:manage:polls
end poll                        channel:manage:polls
delete videos                   channel:manage:videos


# USER AND/OR MODERATOR OF OTHER CHANNEL

send guest star invite          moderator:manage:guest_star
delete guest star invite        moderator:manage:guest_star
assign guest star slot          moderator:manage:guest_star
update guest star slot          moderator:manage:guest_star
update guest star slot settings moderator:manage:guest_star
check automod status            moderation:read
get moderators                  moderation:read
get channel followers           moderator:read:followers
get banned users                moderator:manage:banned_users moderation:read
ban user                        moderator:manage:banned_users
unban user                      moderator:manage:banned_users
get unban requests              moderator:read:unban_requests moderator:manage:unban_requests
resolve unban requests          moderator:manage:unban_requests
get blocked terms               moderator:read:blocked_terms moderator:manage:blocked_terms
add blocked term                moderator:manage:blocked_terms
remove blocked term             moderator:manage:blocked_terms
delete chat messages            moderator:manage:chat_messages
get moderated channels          user:read:moderated_channels
update shield mode status       moderator:manage:shield_mode
get shield mode status          moderator:read:shield_mode moderator:manage:shield_mode
warn chat user                  moderator:manage:warnings
get followed streams            user:read:follows
get channel stream schedule
search categories
search channels
get streams
check user subscription         user:read:subscriptions
get all stream tags
get stream tags
get channel teams
get teams
get users
update user                     user:edit
block user                      user:manage:blocked_users
unblock user                    user:manage:blocked_users
get user extensions             user:read:broadcast user:edit:broadcast
get user active extensions      user:read:broadcast user:edit:broadcast
update user extensions          user:edit:broadcast
get videos
send whisper                    user:manage:whispers
get extension analytics         analytics:read:extensions
get bits leaderboard            bits:read
get channel information
get followed channels           user:read:follows
create custom rewards           channel:manage:redemptions
update custom reward            channel:manage:redemptions
get custom reward               channel:read:redemptions
get custom rewrd redemption     channel:read:redemptions
get chatters                    moderator:read:chatters
get channel emotes
get global emotes
get emote sets
get channel chat badges
get chat settings
get shared chat session
get user emotes                 user:read:emotes
update chat settings            moderator:manage:chat_settings
send chat announcements         moderator:manage:announcements
send a shoutout                 moderator:manage:shoutouts (channel.shoutout.create?)
send a chat message             user:write:chat
get user chat colour
update user chat colour         user:manage:chat_color
create clip                     clips:edit
get clips
get conduits
create conduits
update conduits
delete conduit
get conduit shards
update conduit shards
get content classification labels
get drops entitlement
update drops entitlement
get extension configuration segment
set extension configuration segment
set extension required configuration
send extension pubsub message
get extension live channels
get extension secrets
create extension secret
send extension chat message
get extensions
get released extensions
get extension bits products
update extension bits products
create eventsub subscription
delete eventsub subscription
get eventsub subscription
get top games
get games
manage held automod settings    moderator:manage:automod
get automod settings            moderator:read:automod_settings
update automod settings         moderator:manage:automod_settings
get game analytics              analytics:read:games
get cheermotes


# NO AUTHENTICATION REQUIRED AT ALL?

get channel iCalendar
 +/


// requestTwitchKey
/++
    Starts the key generation terminal wizard.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
 +/
void requestTwitchKey(TwitchPlugin plugin)
{
    import kameloso.logger : LogLevel;
    import kameloso.thread : ThreadMessage;
    import std.datetime.systime : Clock;
    import std.process : Pid, ProcessException, wait;
    import std.stdio : stdout, writeln;

    scope(exit) if (plugin.state.coreSettings.flush) stdout.flush();

    logger.trace();
    logger.log("== <w>Twitch authorisation key generation wizard</> ==");
    enum attemptToOpenMessage = `
<l>Attempting to open a <i>Twitch login page<l> in your default web browser.</>
Follow the instructions and log in to authorise the use of this program with
your <w>BOT</> account.

<l>Then paste the address of the page you are redirected to afterwards here.</>

<i>*</> The redirected address should start with <i>http://localhost</>.
<i>*</> It will probably say "<i>this site can't be reached</>" or "<i>unable to connect</>".
<i>*</> <l>The key generated will be one for the account you are currently logged in as in your browser.</>
  If you are logged into your main Twitch account and you want the bot to use a
  separate account, you will have to <l>log out and log in as that</> first, before
  attempting this. Alternatively, <l>use an incognito/private browser window</>.
<i>*</> If you are running local web server on port <i>80</>, you may have to temporarily
  disable it for this to work.
`;
    writeln(attemptToOpenMessage.expandTags(LogLevel.off));
    if (plugin.state.coreSettings.flush) stdout.flush();

    static immutable scopes =
    [
        /+
            Scopes required for normal chat and channel moderation.
            Refer to the huge list at the top of the file.
         +/
        "chat:read",
        "chat:edit",
        "whispers:read",
        "whispers:edit",
        "channel:moderate",
        "user:manage:whispers",
        "user:write:chat",
        "user:read:follows",
        "user:read:subscriptions",
        "moderation:read",
        "moderator:read:chatters",
        "moderator:read:followers",
        "moderator:manage:chat_messages",
        "moderator:manage:banned_users",
        "moderator:manage:unban_requests",
        "moderator:manage:blocked_terms",
        "moderator:manage:automod",
        "moderator:manage:automod_settings",
        "moderator:manage:chat_settings",
        "moderator:manage:announcements",
        "moderator:manage:shoutouts",
        "moderator:manage:warnings",
        "moderator:manage:shield_mode",
    ];

    Pid browser;
    scope(exit) if (browser !is null) wait(browser);

    enum authNode = "https://id.twitch.tv/oauth2/authorize";
    immutable url = buildAuthNodeURL(authNode, scopes);

    if (plugin.state.coreSettings.force)
    {
        logger.warning("Forcing; not automatically opening browser.");
        printManualURL(url);
        if (plugin.state.coreSettings.flush) stdout.flush();
    }
    else
    {
        try
        {
            import kameloso.platform : openInBrowser;
            openInBrowser(url);
        }
        catch (ProcessException _)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL(url);
            if (plugin.state.coreSettings.flush) stdout.flush();
        }
        catch (Exception _)
        {
            logger.warning("Error: no graphical environment detected");
            printManualURL(url);
            if (plugin.state.coreSettings.flush) stdout.flush();
        }
    }

    plugin.state.bot.pass = readURLAndParseKey(plugin, authNode);
    if (*plugin.state.abort) return;

    writeln();
    logger.info("Validating...");

    immutable expiry = getTokenExpiry(plugin, plugin.state.bot.pass);
    if (*plugin.state.abort) return;

    immutable delta = (expiry - Clock.currTime);
    immutable numDays = delta.total!"days";

    enum isValidPattern = "Your key is valid for another <l>%d</> days.";
    logger.infof(isValidPattern, numDays);
    logger.trace();

    plugin.state.updates |= typeof(plugin.state.updates).bot;
    plugin.state.messages ~= ThreadMessage.save;
}


// requestTwitchSuperKey
/++
    Starts the super-key generation terminal wizard.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
 +/
void requestTwitchSuperKey(TwitchPlugin plugin)
{
    import kameloso.logger : LogLevel;
    import lu.meld : MeldingStrategy, meldInto;
    import std.process : Pid, ProcessException, wait;
    import std.stdio : stdout, writeln;
    import std.datetime.systime : Clock;

    scope(exit) if (plugin.state.coreSettings.flush) stdout.flush();

    logger.trace();
    logger.log("== <w>Twitch authorisation super-key generation wizard</> ==");
    enum message = `
To access certain Twitch functionality, like changing channel settings
(what game is currently being played, etc), the program needs an authorisation
key that corresponds to the owner of that channel.

In the instructions that follow, it is essential that you are logged into the
main <w>STREAMER</> account in your browser.

You also need to supply the channel for which it all relates.
(Channels are Twitch lowercase account names, prepended with a '<i>#</>' sign.)
`;
    writeln(message.expandTags(LogLevel.off));

    string channel;  // mutable
    uint numEmptyLinesEntered;

    while (!channel.length)
    {
        bool benignAbort;

        channel = readChannelName(
            numEmptyLinesEntered,
            benignAbort,
            plugin.state.abort);

        if (*plugin.state.abort || benignAbort) return;
    }

    enum attemptToOpenMessage = `
--------------------------------------------------------------------------------

<l>Attempting to open a <i>Twitch login page<l> in your default web browser.</>
Follow the instructions and log in to authorise the use of this program with
your main <w>STREAMER</> account.

<l>Then paste the address of the page you are redirected to afterwards here.</>

<i>*</> The redirected address should start with <i>http://localhost</>.
<i>*</> It will probably say "<l>this site can't be reached</>" or "<l>unable to connect</>".
<i>*</> <l>The key generated will be one for the account you are currently logged in as in your browser.</>
  You should be logged into your main Twitch account for this key.
<i>*</> If you are running local web server on port <i>80</>, you may have to temporarily
  disable it for this to work.
`;
    writeln(attemptToOpenMessage.expandTags(LogLevel.off));
    if (plugin.state.coreSettings.flush) stdout.flush();

    static immutable scopes =
    [
        /+
            Scopes required for higher-privilege channel management.
            Refer to the huge list at the top of the file.
         +/
        "channel:manage:broadcast",
        "channel:manage:moderators",
        "channel:manage:vips",
        "channel:manage:predictions",
        "channel:manage:raids",
        "channel:manage:polls",
        "channel:read:subscriptions",
        "channel:edit:commercial",
    ];

    Pid browser;
    scope(exit) if (browser !is null) wait(browser);

    enum authNode = "https://id.twitch.tv/oauth2/authorize";
    immutable url = buildAuthNodeURL(authNode, scopes);

    if (plugin.state.coreSettings.force)
    {
        logger.warning("Forcing; not automatically opening browser.");
        printManualURL(url);
        if (plugin.state.coreSettings.flush) stdout.flush();
    }
    else
    {
        try
        {
            import kameloso.platform : openInBrowser;
            openInBrowser(url);
        }
        catch (ProcessException _)
        {
            // Probably we got some platform wrong and command was not found
            logger.warning("Error: could not automatically open browser.");
            printManualURL(url);
            if (plugin.state.coreSettings.flush) stdout.flush();
        }
    }

    Credentials inputCreds;
    inputCreds.broadcasterKey = readURLAndParseKey(plugin, authNode);
    if (*plugin.state.abort) return;

    auto creds = channel in plugin.secretsByChannel;
    if (!creds)
    {
        plugin.secretsByChannel[channel] = inputCreds;
        creds = channel in plugin.secretsByChannel;
    }

    inputCreds.meldInto!(MeldingStrategy.aggressive)(*creds);

    writeln();
    logger.info("Validating...");

    immutable expiry = getTokenExpiry(plugin, creds.broadcasterKey);
    if (*plugin.state.abort) return;

    immutable delta = (expiry - Clock.currTime);
    immutable numDays = delta.total!"days";

    enum isValidPattern = "Your key is valid for another <l>%d</> days.";
    logger.infof(isValidPattern, numDays);
    logger.trace();

    creds.broadcasterBearerToken = "Bearer " ~ creds.broadcasterKey;
    creds.broadcasterKeyExpiry = expiry.toUnixTime();
    saveSecretsToDisk(plugin.secretsByChannel, plugin.secretsFile);
}


// readURLAndParseKey
/++
    Reads a URL from standard in and parses an OAuth key from it.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        authNode = Authentication node URL, to detect whether the wrong link was pasted.

    Returns:
        An OAuth token key parsed from a pasted URL string.
 +/
private auto readURLAndParseKey(TwitchPlugin plugin, const string authNode)
{
    import kameloso.logger : LogLevel;
    import lu.string : advancePast, stripped;
    import std.algorithm.searching : canFind;
    import std.stdio : readln, stdin, stdout, write, writeln;

    string key;

    while (!key.length)
    {
        scope(exit) if (plugin.state.coreSettings.flush) stdout.flush();

        enum pasteMessage = "<l>Paste the address of empty the page you were " ~
            "redirected to here (empty line exits):</>

> ";
        write(pasteMessage.expandTags(LogLevel.off));
        stdout.flush();
        stdin.flush();
        immutable readURL = readln().stripped;

        if (!readURL.length || *plugin.state.abort)
        {
            writeln();
            logger.warning("Aborting.");
            logger.trace();
            *plugin.state.abort = true;
            return string.init;
        }

        if (readURL.length == 30)
        {
            // As is
            key = readURL;
        }
        else if (!readURL.canFind("access_token="))
        {
            import std.algorithm.searching : startsWith;

            writeln();

            if (readURL.startsWith(authNode))
            {
                enum wrongPageMessage = "Not that page; the empty page you're " ~
                    "redirected to after clicking <l>Authorize</>.";
                logger.error(wrongPageMessage);
            }
            else
            {
                logger.error("Could not make sense of URL. Try copying again or file a bug.");
            }

            writeln();
            continue;
        }

        string slice = readURL;  // mutable
        slice.advancePast("access_token=");
        key = slice.advancePast('&');

        if (key.length != 30L)
        {
            writeln();
            logger.error("Invalid key length!");
            writeln();
            key = string.init;  // reset it so the while loop repeats
        }
    }

    return key;
}


// buildAuthNodeURL
/++
    Constructs an authorisation node URL with the passed scopes.

    Params:
        authNode = Base authorisation node URL.
        scopes = OAuth scope string array.

    Returns:
        A URL string.
 +/
private auto buildAuthNodeURL(const string authNode, const string[] scopes)
{
    import std.array : join;
    import std.conv : text;

    return text(
        authNode,
        "?response_type=token",
        "&client_id=", TwitchPlugin.clientID,
        "&redirect_uri=http://localhost",
        "&scope=", scopes.join('+'),
        "&force_verify=true",
        "&state=kameloso");
}


// getTokenExpiry
/++
    Validates an authorisation token and returns a [std.datetime.systime.SysTime|SysTime]
    of when it expires.

    Params:
        plugin = The current [kameloso.plugins.twitch.TwitchPlugin|TwitchPlugin].
        authToken = Authorisation token to validate and check expiry of.

    Returns:
        A [std.datetime.systime.SysTime|SysTime] of when the passed token expires.
 +/
auto getTokenExpiry(TwitchPlugin plugin, const string authToken)
in (Fiber.getThis(), "Tried to call `getTokenExpiry` from outside a fiber")
{
    import kameloso.plugins.twitch.api : getValidation;
    import std.datetime.systime : Clock, SysTime;

    foreach (immutable i; 0..TwitchPlugin.delegateRetries)
    {
        try
        {
            immutable validationJSON = getValidation(plugin, authToken, async: false);
            plugin.state.client.nickname = validationJSON["login"].str;
            plugin.state.updates |= typeof(plugin.state.updates).client;
            immutable expiresIn = validationJSON["expires_in"].integer;
            immutable expiresWhen = SysTime.fromUnixTime(Clock.currTime.toUnixTime() + expiresIn);
            return expiresWhen;
        }
        catch (Exception e)
        {
            // Retry until we reach the retry limit, then rethrow
            if (i < TwitchPlugin.delegateRetries-1) continue;
            throw e;
        }
    }

    assert(0, "Unreachable");
}

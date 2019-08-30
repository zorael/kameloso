/++
 +  The Twitch Support service post-processes `kameloso.irc.defs.IRCEvent`s after
 +  they are parsed but before they are sent to the plugins for handling, and
 +  deals with Twitch-specifics. Those include extracting the colour someone's
 +  name should be printed in, their alias/"display name" (generally their
 +  nickname cased), converting the event to some event types unique to Twitch, etc.
 +
 +  It has no bot commands and no event handlers; it only post-processes events.
 +
 +  It is useless on other servers but crucial on Twitch itself. Even enabled
 +  it won't slow the bot down though, as the very fist thing it does is to
 +  verify that it is on a Twitch server, and aborts and returns if not.
 +/
module kameloso.plugins.twitchsupport;

version(WithPlugins):
version(TwitchSupport):

//version = TwitchWarnings;

private:

import kameloso.plugins.common;
import kameloso.irc.defs;

version(Colours)
{
    import kameloso.terminal : TerminalForeground;
}


// postprocess
/++
 +  Handle Twitch specifics, modifying the `kameloso.irc.defs.IRCEvent` to add
 +  things like `kameloso.irc.defs.IRCEvent.colour` and differentiate between
 +  temporary and permanent bans.
 +/
void postprocess(TwitchSupportService service, ref IRCEvent event)
{
    // isEnabled doesn't work here since we're not offering to disable this plugin
    if (service.state.client.server.daemon != IRCServer.Daemon.twitch) return;

    service.parseTwitchTags(event);

    with (IRCEvent.Type)
    {
        if ((event.type == CLEARCHAT) && event.target.nickname.length && event.sender.isServer)
        {
            // Stay CLEARCHAT if no target nickname
            event.type = (event.count > 0) ? TWITCH_TIMEOUT : TWITCH_BAN;
        }
    }

    if (event.sender.nickname.length)
    {
        // Twitch nicknames are always the same as the user accounts; the
        // displayed name/alias is sent separately as a "display-name" IRCv3 tag
        event.sender.account = event.sender.nickname;
    }
    else if (event.sender.alias_.length)
    {
        // If no nickname yet an alias, it may be an anonymous subgift/bulkgift
        // where the msg-id appeared before the display-name in the tags.
        // Clear it.
        event.sender.alias_ = string.init;
    }
}


// parseTwitchTags
/++
 +  Parses a Twitch event's IRCv3 tags.
 +
 +  The event is passed by ref as many tags necessitate changes to it.
 +
 +  Params:
 +      service = Current `TwitchSupportService`.
 +      event = Reference to the `kameloso.irc.defs.IRCEvent` whose tags should be parsed.
 +/
void parseTwitchTags(TwitchSupportService service, ref IRCEvent event)
{
    import kameloso.irc.common : decodeIRCv3String;
    import std.algorithm.iteration : splitter;

    // https://dev.twitch.tv/docs/v5/guides/irc/#twitch-irc-capability-tags

    if (!event.tags.length) return;

    /++
     +  Clears a user's address and class.
     +
     +  We invent users on some events, like (re-)subs, where there before were
     +  only the server announcing some event originating from that user. When
     +  we rewrite it, the server's address and its classification as special
     +  remain. Reset those.
     +/
    static void resetUser(ref IRCUser user)
    {
        user.address = string.init;  // Clear server address
        user.class_ = IRCUser.Class.unset;
    }

    auto tagRange = event.tags.splitter(";");

    with (IRCEvent)
    foreach (tag; tagRange)
    {
        import kameloso.string : contains, nom;

        immutable key = tag.nom("=");
        immutable value = tag;

        version(TwitchWarnings)
        {
            import kameloso.common : logger;
            import std.conv : to;

            static void printTags(typeof(tagRange) tagRange, const string highlight = string.init)
            {
                foreach (immutable tagline; tagRange)
                {
                    import kameloso.common : settings;
                    import std.stdio : stdout, writef, writeln;

                    string slice = tagline;  // mutable
                    immutable key = slice.nom('=');

                    writef(`%-35s"%s"`, key, slice);
                    writeln((highlight.length && (slice == highlight)) ? " <-- !" : string.init);

                    if (settings.flush) stdout.flush();
                }
            }
        }

        switch (key)
        {
        case "msg-id":
            // The type of notice (not the ID) / A message ID string.
            // Can be used for i18ln. Valid values: see
            // Msg-id Tags for the NOTICE Commands Capability.
            // https://dev.twitch.tv/docs/irc#msg-id-tags-for-the-notice-commands-capability
            // https://swiftyspiffy.com/TwitchLib/Client/_msg_ids_8cs_source.html
            // https://dev.twitch.tv/docs/irc/msg-id/

            /*
                sub
                resub
                charity
                already_banned          <user> is already banned in this room.
                already_emote_only_off  This room is not in emote-only mode.
                already_emote_only_on   This room is already in emote-only mode.
                already_r9k_off         This room is not in r9k mode.
                already_r9k_on          This room is already in r9k mode.
                already_subs_off        This room is not in subscribers-only mode.
                already_subs_on         This room is already in subscribers-only mode.
                bad_host_hosting        This channel is hosting <channel>.
                bad_unban_no_ban        <user> is not banned from this room.
                ban_success             <user> is banned from this room.
                emote_only_off          This room is no longer in emote-only mode.
                emote_only_on           This room is now in emote-only mode.
                host_off                Exited host mode.
                host_on                 Now hosting <channel>.
                hosts_remaining         There are <number> host commands remaining this half hour.
                msg_channel_suspended   This channel is suspended.
                r9k_off                 This room is no longer in r9k mode.
                r9k_on                  This room is now in r9k mode.
                slow_off                This room is no longer in slow mode.
                slow_on                 This room is now in slow mode. You may send messages every <slow seconds> seconds.
                subs_off                This room is no longer in subscribers-only mode.
                subs_on                 This room is now in subscribers-only mode.
                timeout_success         <user> has been timed out for <duration> seconds.
                unban_success           <user> is no longer banned from this chat room.
                unrecognized_cmd        Unrecognized command: <command>
                raid                    Raiders from <other channel> have joined!\n
            */
            switch (value)
            {
            case "sub":
            case "resub":
/+
badge-info                         "subscriber/3"
badges                             "subscriber/3,premium/1"
color                              "#008000"
display-name                       "krufster"
emotes                             ""
flags                              ""
id                                 "b97b13a2-8966-4d18-b634-61a04aefcb92"
login                              "krufster"
mod                                "0"
msg-id                             "resub"
msg-param-cumulative-months        "3"
msg-param-months                   "0"
msg-param-should-share-streak      "1"
msg-param-streak-months            "2"
msg-param-sub-plan-name            "Dr\sDisRespect"
msg-param-sub-plan                 "Prime"
room-id                            "17337557"
subscriber                         "1"
system-msg                         "krufster\ssubscribed\swith\sTwitch\sPrime.\sThey've\ssubscribed\sfor\s3\smonths,\scurrently\son\sa\s2\smonth\sstreak!"
tmi-sent-ts                        "1565380381758"
user-id                            "83176999"
user-type                          ""
+/
                event.type = Type.TWITCH_SUB;
                break;

            case "subgift":
                // "We added the msg-id “anonsubgift” to the user-notice which
                // defaults the sender to the channel owner"
                /+
                    For anything anonomous
                    The channel ID and Channel name are set as normal
                    The Recipienet is set as normal
                    The person giving the gift is anonomous

                    https://discuss.dev.twitch.tv/t/msg-id-purchase/22067/8
                 +/
                // Solution: throw money at it.
/+
[21:00:40] [subgift] [#beardageddon] AnAnonymousGifter (dolochild): "An anonymous user gifted a Tier 1 sub to dolochild!" (1000)
-- IRCEvent
     Type type                    TWITCH_SUBGIFT
   string raw                    ":tmi.twitch.tv USERNOTICE #beardageddon"(39)
  IRCUser sender                 <struct>
   string channel                "#beardageddon"(13)
  IRCUser target                 <struct>
   string content                "An anonymous user gifted a Tier 1 sub to dolochild!"(51)
   string aux                    "1000"(4)
   string tags                   (below)
     uint num                     0
      int count                   0
      int altcount                0
     long time                    1565377240
   string errors                  ""(0)
   string emotes                  ""(0)
   string id                     "30f00e1d-0724-4c30-b265-0c8695c5e748"(36)

badge-info                         ""
badges                             ""
color                              ""
display-name                       "AnAnonymousGifter"
emotes                             ""
flags                              ""
id                                 "30f00e1d-0724-4c30-b265-0c8695c5e748"
login                              "ananonymousgifter"
mod                                "0"
msg-id                             "subgift"
msg-param-fun-string               "FunStringOne"
msg-param-months                   "2"
msg-param-origin-id                "da\s39\sa3\see\s5e\s6b\s4b\s0d\s32\s55\sbf\sef\s95\s60\s18\s90\saf\sd8\s07\s09"
msg-param-recipient-display-name   "dolochild"
msg-param-recipient-id             "124388477"
msg-param-recipient-user-name      "dolochild"
msg-param-sub-plan-name            "Channel\sSubscription\s(beardageddon)"
msg-param-sub-plan                 "1000"
room-id                            "74488574"
subscriber                         "0"
system-msg                         "An\sanonymous\suser\sgifted\sa\sTier\s1\ssub\sto\sdolochild!\s"
tmi-sent-ts                        "1565377240017"
user-id                            "274598607"
user-type                          ""

badge-info                         "subscriber/2"
badges                             "subscriber/0,sub-gifter/1"
color                              "#DAA520"
display-name                       "Kraltic"
emotes                             ""
flags                              ""
id                                 "eaac38a6-da95-4f22-b6bd-52faedc65b79"
login                              "kraltic"
mod                                "0"
msg-id                             "subgift"
msg-param-months                   "1"
msg-param-origin-id                "da\s39\sa3\see\s5e\s6b\s4b\s0d\s32\s55\sbf\sef\s95\s60\s18\s90\saf\sd8\s07\s09"
msg-param-recipient-display-name   "daveeedpistolass"
msg-param-recipient-id             "245630631"
msg-param-recipient-user-name      "daveeedpistolass"
msg-param-sender-count             "2"
msg-param-sub-plan-name            "Dr\sDisRespect"
msg-param-sub-plan                 "1000"
room-id                            "17337557"
subscriber                         "1"
system-msg                         "Kraltic\sgifted\sa\sTier\s1\ssub\sto\sdaveeedpistolass!\sThey\shave\sgiven\s2\sGift\sSubs\sin\sthe\schannel!"
tmi-sent-ts                        "1565380535752"
user-id                            "98897370"
user-type                          ""
+/
                event.type = Type.TWITCH_SUBGIFT;

                if (event.sender.nickname == "ananonymousgifter")
                {
                    // Make anonymous gifts detectable by no nickname.
                    event.sender.nickname = string.init;
                    event.sender.alias_ = string.init;
                }
                break;

            case "anonsubgift":
                version(TwitchWarnings)
                {
                    logger.trace(event.raw);
                    printTags(tagRange);
                }
                goto case "subgift";

            case "submysterygift":
/+
badge-info                         "subscriber/8"
badges                             "subscriber/6,sub-gifter/1000"
color                              ""
display-name                       "kinghaua35"
emotes                             ""
flags                              ""
id                                 "fbf4e664-95f4-4205-919b-a71268bb71a6"
login                              "kinghaua35"
mod                                "0"
msg-id                             "submysterygift"
msg-param-mass-gift-count          "50"
msg-param-origin-id                "27\s3f\sc2\s0d\sde\s69\sa2\sb7\s06\sba\sb3\sb4\s9b\s4e\sd1\s2b\s8c\s65\s83\s27"
msg-param-sender-count             "2230"
msg-param-sub-plan                 "1000"
room-id                            "17337557"
subscriber                         "1"
system-msg                         "kinghaua35\sis\sgifting\s50\sTier\s1\sSubs\sto\sDrDisrespect's\scommunity!\sThey've\sgifted\sa\stotal\sof\s2230\sin\sthe\schannel!"
tmi-sent-ts                        "1565381426467"
user-id                            "215907614"
user-type                          ""
+/
                event.type = Type.TWITCH_BULKGIFT;
                break;

            case "ritual":
/+
-- IRCEvent
     Type type                    TWITCH_RITUAL
   string raw                    ":tmi.twitch.tv USERNOTICE #rdulive :VoHiYo"(42)
  IRCUser sender                 <struct>
   string channel                "#rdulive"(8)
  IRCUser target                 <struct> (init)
   string content                "VoHiYo"(6)
   string aux                     ""(0)
   string tags                   (below)
     uint num                     0
      int count                   0
      int altcount                0
     long time                    1565380797
   string errors                  ""(0)
   string emotes                 "81274:0-5"(9)
   string id                     "5f8659bc-646f-407d-9d75-25dbfc6745ff"(36)

badge-info                         ""
badges                             ""
color                              "#00FF7F"
display-name                       "VNXL"
emotes                             "81274:0-5"
flags                              ""
id                                 "5f8659bc-646f-407d-9d75-25dbfc6745ff"
login                              "vnxl"
mod                                "0"
msg-id                             "ritual"
msg-param-ritual-name              "new_chatter"
room-id                            "59965916"
subscriber                         "0"
system-msg                         "@VNXL\sis\snew\shere.\sSay\shello!"
tmi-sent-ts                        "1565380719028"
user-id                            "81266025"
user-type                          ""
+/
                event.type = Type.TWITCH_RITUAL;
                break;

            case "rewardgift":
/+
-- IRCEvent
     Type type                    TWITCH_REWARDGIFT                                                                                                                                        string raw                    ":tmi.twitch.tv USERNOTICE #overwatchleague :A Cheer shared Rewards to 20 others in Chat!"(88)                                                           IRCUser sender                 <struct>
   string channel                "#overwatchleague"(16)
  IRCUser target                 <struct> (init)
   string content                "A Cheer shared Rewards to 20 others in Chat!"(44)
   string aux                     ""(0)
   string tags                   (below)
     uint num                     0
      int count                   0
      int altcount                0
     long time                    1565309300
   string errors                  ""(0)
   string emotes                  ""(0)
   string id                     "9d7e2298-9ee4-4e43-abb5-328ffae83a31"(36)

badge-info                         ""
badges                             "subscriber/0,bits/1000"
color                              "#DAA520"
display-name                       "Gerath94"
emotes                             ""
flags                              ""
id                                 "9d7e2298-9ee4-4e43-abb5-328ffae83a31"
login                              "gerath94"
mod                                "0"
msg-id                             "rewardgift"
msg-param-bits-amount              "500"
msg-param-domain                   "owl2019"
msg-param-min-cheer-amount         "300"
msg-param-selected-count           "20"
room-id                            "137512364"
subscriber                         "1"
system-msg                         "reward"
tmi-sent-ts                        "1565309265716"
user-id                            "81251937"
user-type                          ""

badge-info                         ""
badges                             "subscriber/0,bits/100"
color                              "#0000FF"
display-name                       "Flori_DE"
emotes                             ""
flags                              ""
id                                 "4d4953ce-b9a6-460c-aec1-4bfdaaae342b"
login                              "flori_de"
mod                                "0"
msg-id                             "rewardgift"
msg-param-bits-amount              "300"
msg-param-domain                   "owl2019"
msg-param-min-cheer-amount         "300"
msg-param-selected-count           "10"
room-id                            "137512364"
subscriber                         "1"
system-msg                         "reward"
tmi-sent-ts                        "1565381918616"
user-id                            "170554786"
user-type                          ""
+/
                event.type = Type.TWITCH_REWARDGIFT;
                break;

            case "raid":
/+
badge-info                         ""
badges                             ""
color                              "#FF0000"
display-name                       "Not_A_Banana"
emotes                             ""
flags                              ""
id                                 "28d76102-e05b-4185-a30e-80ee88572d50"
login                              "not_a_banana"
mod                                "0"
msg-id                             "raid"
msg-param-displayName              "Not_A_Banana"
msg-param-login                    "not_a_banana"
msg-param-profileImageURL          "https://static-cdn.jtvnw.net/jtv_user_pictures/not_a_banana-profile_image-fee36a93a752bf70-70x70.jpeg"
msg-param-viewerCount              "3"
room-id                            "57292293"
subscriber                         "0"
system-msg                         "3\sraiders\sfrom\sNot_A_Banana\shave\sjoined!"
tmi-sent-ts                        "1565387919848"
user-id                            "50143288"
user-type                          ""
+/
                event.type = Type.TWITCH_RAID;
                break;

            case "unraid":
/+
user-type                          ""
display-name                       "dakotaz"
id                                 "55245012-9790-4599-b51c-90b1cac0ced7"
mod                                "0"
tmi-sent-ts                        "1565104791674"
user-id                            "39298218"
login                              "dakotaz"
badge-info                         "subscriber/71"
flags                              ""
emotes                             ""
color                              "#AA79EB"
msg-id                             "unraid"
system-msg                         "The\sraid\shas\sbeen\scancelled."
subscriber                         "1"
badges                             "broadcaster/1,subscriber/60,sub-gifter/1000"
room-id                            "39298218"
+/
                event.type = Type.TWITCH_UNRAID;
                break;

            case "charity":
                //msg-id = charity
                //msg-param-charity-days-remaining = 11
                //msg-param-charity-hashtag = #charity
                //msg-param-charity-hours-remaining = 286
                //msg-param-charity-learn-more = https://link.twitch.tv/blizzardofbits
                //msg-param-charity-name = Direct\sRelief
                //msg-param-total = 135770
                // Charity has too many fields to fit an IRCEvent as they are currently
                // Cram as much into aux as possible
                import kameloso.string : beginsWith;
                import std.algorithm.iteration : filter;
                import std.conv : to;
                import std.typecons : Flag, No, Yes;

                event.type = Type.TWITCH_CHARITY;

                string[string] charityAA;
                auto charityTags = tagRange
                    .filter!(tagline => tagline.beginsWith("msg-param-charity"));

                foreach (immutable tagline; charityTags)
                {
                    string slice = tagline;  // mutable
                    immutable charityKey = slice.nom('=');
                    charityAA[charityKey] = slice;
                }

                if (const charityName = "msg-param-charity-name" in charityAA)
                {
                    import kameloso.string : escapeControlCharacters, strippedRight;

                    event.aux = (*charityName)
                        .decodeIRCv3String
                        .strippedRight
                        .escapeControlCharacters!(Yes.remove);
                }

                if (const charityLink = "msg-param-charity-learn-more" in charityAA)
                {
                    if (event.aux.length) event.aux ~= " (" ~ *charityLink ~ ')';
                    else
                    {
                        event.aux = *charityLink;
                    }
                }

                if (const charityHashtag = "msg-param-charity-hashtag" in charityAA)
                {
                    if (event.aux.length) event.aux ~= ' ' ~ *charityHashtag;
                    else
                    {
                        event.aux = *charityHashtag;
                    }
                }

                // Doesn't start with msg-param-charity but it will be set later down
                /*if (const charityTotal = "msg-param-total" in charityAA)
                {
                    event.count = (*charityTotal).to!int;
                }*/

                if (const charityRemaining = "msg-param-charity-hours-remaining" in charityAA)
                {
                    event.altcount = (*charityRemaining).to!int;
                }

                version(TwitchWarnings)
                {
                    import kameloso.printing : printObject;

                    printObject(event);
                    printTags(tagRange);
                }
                break;

            case "giftpaidupgrade":
/+
user-type                          ""
msg-param-sender-name              "blamebruce"
display-name                       "LouCmusic_"
id                                 "23c5ff34-778b-47fa-935a-beedbe0c598c"
mod                                "0"
tmi-sent-ts                        "1565043295367"
user-id                            "149718683"
login                              "loucmusic_"
badge-info                         "subscriber/1"
flags                              ""
emotes                             ""
color                              "#FF69B4"
msg-id                             "giftpaidupgrade"
msg-param-sender-login             "blamebruce"
system-msg                         "LouCmusic_\sis\scontinuing\sthe\sGift\sSub\sthey\sgot\sfrom\sblamebruce!"
subscriber                         "1"
badges                             "subscriber/0,premium/1"
room-id                            "60056333"
+/
                event.type = Type.TWITCH_GIFTCHAIN;

                if (event.sender.nickname == "ananonymousgifter")
                {
                    // Make anonymous gifts detectable by no nickname.
                    event.sender.nickname = string.init;
                    event.sender.alias_ = string.init;
                }
                break;

            case "anongiftpaidupgrade":
                version(TwitchWarnings)
                {
                    logger.trace(event.raw);
                    printTags(tagRange);
                }
                goto case "giftpaidupgrade";

            case "primepaidupgrade":
/+
user-type                          ""
display-name                       "luton9"
id                                 "d851692c-2987-4534-b58f-95cb0fc5b630"
mod                                "0"
tmi-sent-ts                        "1565036616388"
user-id                            "430838491"
login                              "luton9"
badge-info                         "subscriber/2"
flags                              ""
emotes                             ""
msg-param-sub-plan                 "1000"
color                              ""
msg-id                             "primepaidupgrade"
system-msg                         "luton9\sconverted\sfrom\sa\sTwitch\sPrime\ssub\sto\sa\sTier\s1\ssub!"
subscriber                         "1"
badges                             "subscriber/0,premium/1"
room-id                            "12875057"
+/
                event.type = Type.TWITCH_SUBUPGRADE;
                break;

            case "bitsbadgetier":
                // User just earned a badge for a tier of bits
/+
[12:31:59] [bitsbadgetier] [#mrfreshasian] blasterdark9000 [SC]: "new badge hype :)" {1000}
user-type                          ""
display-name                       "blasterdark9000"
id                                 "0f454461-251a-4fad-a2b4-bc12fa776206"
mod                                "0"
msg-param-threshold                "1000"
tmi-sent-ts                        "1565086861733"
user-id                            "123361548"
login                              "blasterdark9000"
badge-info                         "subscriber/7"
flags                              ""
emotes                             "1:15-16"
color                              "#DAA520"
msg-id                             "bitsbadgetier"
system-msg                         "bits\sbadge\stier\snotification"
subscriber                         "1"
badges                             "subscriber/6,bits/1000"
room-id                            "38594688"
+/
                event.type = Type.TWITCH_BITSBADGETIER;
                break;

            case "extendsub":
/+
badge-info                         "subscriber/1"
badges                             "subscriber/0,bits-charity/1"
color                              "#FF0000"
display-name                       "ensqa473"
emotes                             ""
flags                              ""
id                                 "4abc1a50-51b3-4659-8c12-e1d8c3652963"
login                              "ensqa473"
mod                                "0"
msg-id                             "extendsub"
msg-param-sub-benefit-end-month    "9"
msg-param-sub-plan                 "1000"
room-id                            "17337557"
subscriber                         "1"
system-msg                         "ensqa473\sextended\stheir\sTier\s1\ssubscription\sthrough\sSeptember!"
tmi-sent-ts                        "1565384774599"
user-id                            "237654991"
user-type
+/
                event.type = Type.TWITCH_EXTENDSUB;
                break;

            /*case "bad_ban_admin":
            case "bad_ban_anon":
            case "bad_ban_broadcaster":
            case "bad_ban_global_mod":
            case "bad_ban_mod":
            case "bad_ban_self":
            case "bad_ban_staff":
            case "bad_commercial_error":
            case "bad_delete_message_broadcaster":
            case "bad_delete_message_mod":
            case "bad_delete_message_error":
            case "bad_host_error":
            case "bad_host_hosting":
            case "bad_host_rate_exceeded":
            case "bad_host_rejected":
            case "bad_host_self":
            case "bad_marker_client":
            case "bad_mod_banned":
            case "bad_mod_mod":
            case "bad_slow_duration":
            case "bad_timeout_admin":
            case "bad_timeout_broadcaster":
            case "bad_timeout_duration":
            case "bad_timeout_global_mod":
            case "bad_timeout_mod":
            case "bad_timeout_self":
            case "bad_timeout_staff":
            case "bad_unban_no_ban":
            case "bad_unhost_error":
            case "bad_unmod_mod":*/

            case "already_banned":
            case "already_emote_only_on":
            case "already_emote_only_off":
            case "already_r9k_on":
            case "already_r9k_off":
            case "already_subs_on":
            case "already_subs_off":
            case "host_tagline_length_error":
            case "invalid_user":
            case "msg_bad_characters":
            case "msg_channel_blocked":
            case "msg_r9k":
            case "msg_ratelimit":
            case "msg_rejected_mandatory":
            case "msg_room_not_found":
            case "msg_suspended":
            case "msg_timedout":
            case "no_help":
            case "no_mods":
            case "not_hosting":
            case "no_permission":
            case "raid_already_raiding":
            case "raid_error_forbidden":
            case "raid_error_self":
            case "raid_error_too_many_viewers":
            case "raid_error_unexpected":
            case "timeout_no_timeout":
            case "unraid_error_no_active_raid":
            case "unraid_error_unexpected":
            case "unrecognized_cmd":
            case "unsupported_chatrooms_cmd":
            case "untimeout_banned":
            case "whisper_banned":
            case "whisper_banned_recipient":
            case "whisper_restricted_recipient":
            case "whisper_invalid_args":
            case "whisper_invalid_login":
            case "whisper_invalid_self":
            case "whisper_limit_per_min":
            case "whisper_limit_per_sec":
            case "whisper_restricted":
            case "msg_subsonly":
            case "msg_verified_email":
            case "msg_slowmode":
            case "tos_ban":
            case "msg_channel_suspended":
            case "msg_banned":
            case "msg_duplicate":
            case "msg_facebook":
            case "turbo_only_color":
                // Generic Twitch error.
                event.type = Type.TWITCH_ERROR;
                event.aux = value;
                break;

            case "emote_only_on":
            case "emote_only_off":
            case "r9k_on":
            case "r9k_off":
            case "slow_on":
            case "slow_off":
            case "subs_on":
            case "subs_off":
            case "followers_on":
            case "followers_off":
            case "followers_on_zero":
            case "host_on":
            case "host_off":

            /*case "usage_ban":
            case "usage_clear":
            case "usage_color":
            case "usage_commercial":
            case "usage_disconnect":
            case "usage_emote_only_off":
            case "usage_emote_only_on":
            case "usage_followers_off":
            case "usage_followers_on":
            case "usage_help":
            case "usage_host":
            case "usage_marker":
            case "usage_me":
            case "usage_mod":
            case "usage_mods":
            case "usage_r9k_off":
            case "usage_r9k_on":
            case "usage_raid":
            case "usage_slow_off":
            case "usage_slow_on":
            case "usage_subs_off":
            case "usage_subs_on":
            case "usage_timeout":
            case "usage_unban":
            case "usage_unhost":
            case "usage_unmod":
            case "usage_unraid":
            case "usage_untimeout":*/

            case "host_success_viewers":
            case "hosts_remaining":
            case "mod_success":
            case "msg_emotesonly":
            case "msg_followersonly":
            case "msg_followersonly_followed":
            case "msg_followersonly_zero":
            case "msg_rejected":  // "being checked by mods"
            case "raid_notice_mature":
            case "raid_notice_restricted_chat":
            case "room_mods":
            case "timeout_success":
            case "unban_success":
            case "unmod_success":
            case "unraid_success":
            case "untimeout_success":
            case "cmds_available":
            case "color_changed":
            case "commercial_success":
            case "delete_message_success":
            case "ban_success":
            case "host_target_went_offline":
            case "host_success":
                // Generic Twitch server reply.
                event.type = Type.TWITCH_NOTICE;
                event.aux = value;
                break;

            default:
                import kameloso.string : beginsWith;

                version(TwitchWarnings)
                {
                    if (event.aux.length)
                    {
                        logger.warning("msg-id ", value, " overwrote an aux: ", event.aux);
                        logger.trace(event.raw);
                        printTags(tagRange, event.aux);
                    }
                }

                event.aux = value;

                if (value.beginsWith("bad_"))
                {
                    event.type = Type.TWITCH_ERROR;
                    break;
                }
                else if (value.beginsWith("usage_"))
                {
                    event.type = Type.TWITCH_NOTICE;
                    break;
                }

                version(TwitchWarnings)
                {
                    import kameloso.common : logger;
                    import kameloso.printing : printObject;
                    import kameloso.terminal : TerminalToken;
                    import std.algorithm.iteration : joiner;

                    logger.warning("Unknown Twitch msg-id: ", value, cast(char)TerminalToken.bell);
                    printObject(event);
                    printTags(tagRange);
                }
                break;
            }
            break;

        ////////////////////////////////////////////////////////////////////////

         case "display-name":
            // The user’s display name, escaped as described in the IRCv3 spec.
            // This is empty if it is never set.
            import kameloso.string : strippedRight;

            if (!value.length) break;

            immutable alias_ = value.contains('\\') ? decodeIRCv3String(value).strippedRight : value;

            if ((event.type == Type.USERSTATE) || (event.type == Type.GLOBALUSERSTATE))
            {
                // USERSTATE describes the bot in the context of a specific channel,
                // such as what badges are available. It's *always* about the bot,
                // so expose the display name in event.target and let Persistence store it.
                event.target = event.sender;  // get badges etc
                event.target.nickname = service.state.client.nickname;
                event.target.class_ = IRCUser.Class.admin;
                event.target.alias_ = alias_;
                event.target.address = string.init;

                if (!service.state.client.alias_.length)
                {
                    // Also store the alias in the IRCClient, for highlighting purposes
                    // *ASSUME* it never changes during runtime.
                    service.state.client.alias_ = alias_;
                    service.state.client.updated = true;
                }
            }
            else
            {
                // The display name of the sender.
                event.sender.alias_ = alias_;
            }
            break;

        case "badges":
            // Comma-separated list of chat badges and the version of each
            // badge (each in the format <badge>/<version>, such as admin/1).
            // Valid badge values: admin, bits, broadcaster, global_mod,
            // moderator, subscriber, staff, turbo.
            // Save the whole list, let the printer deal with which to display
            // Set an empty list to a placeholder asterisk
            event.sender.badges = value.length ? value : "*";
            break;

        case "system-msg":
        case "ban-reason":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // The moderator’s reason for the timeout or ban.
            // system-msg: The message printed in chat along with this notice.
            import kameloso.string : escapeControlCharacters, strippedRight;
            import std.typecons : No, Yes;

            if (!value.length) break;

            if (event.type == Type.TWITCH_RITUAL)
            {
                event.aux = value
                    .decodeIRCv3String
                    .strippedRight
                    .escapeControlCharacters!(Yes.remove);
                break;
            }

            if (!event.content.length)
            {
                event.content = value
                    .decodeIRCv3String
                    .strippedRight
                    .escapeControlCharacters!(Yes.remove);
            }
            break;

        case "emote-only":
            // We don't conflate ACTION emotes and emote-only messages anymore
            /*if (value == "0") break;
            if (event.type == Type.CHAN) event.type = Type.EMOTE;*/
            break;

        case "msg-param-recipient-display-name":
        case "msg-param-sender-name":
            // In a GIFTCHAIN the display name of the one who started the gift sub train?
            event.target.alias_ = value;
            break;

        case "msg-param-recipient-user-name":
        case "msg-param-sender-login":
            // In a GIFTCHAIN the one who started the gift sub train?
            event.target.nickname = value;
            break;

        case "msg-param-displayName":
            // RAID; sender alias and thus raiding channel cased
            event.sender.alias_ = value;
            break;

        case "msg-param-login":
        case "login":
            // RAID; real sender nickname and thus raiding channel lowercased
            // CLEARMSG, SUBGIFT, lots
            if (value != "ananonymousgifter")
            {
                event.sender.nickname = value;
                resetUser(event.sender);
            }
            break;

        case "color":
            version(Colours)
            {
                // Hexadecimal RGB colour code. This is empty if it is never set.
                if (value.length) event.sender.colour = value[1..$];
            }
            break;

        case "bits":
            /*  (Optional) The amount of cheer/bits employed by the user.
                All instances of these regular expressions:

                    /(^\|\s)<emote-name>\d+(\s\|$)/

                (where <emote-name> is an emote name returned by the Get
                Cheermotes endpoint), should be replaced with the appropriate
                emote:

                static-cdn.jtvnw.net/bits/<theme>/<type>/<color>/<size>

                * theme – light or dark
                * type – animated or static
                * color – red for 10000+ bits, blue for 5000-9999, green for
                  1000-4999, purple for 100-999, gray for 1-99
                * size – A digit between 1 and 4
            */
/+
[01:30:29] [cheer] [#pace22] Jay_027 [SC] Cheer100 Cheer100 what mouse do you use for SOT? {200}
user-type           ""
display-name        "Jay_027"
id                  "6a4098be-c959-4803-9e9d-2480edad577e"
mod                 "0"
tmi-sent-ts         "1564961429282"
user-id             "82203804"
turbo               "0"
badge-info          "subscriber/6"
flags               ""
emotes              ""
bits                "200"
color               "#E4FF00"
subscriber          "1"
badges              "subscriber/6,bits/1000"
room-id             "31457014"
+/
            import std.conv : to;
            event.type = Type.TWITCH_CHEER;

            version(TwitchWarnings)
            {
                if (event.count != 0)
                {
                    logger.warning(key, " overwrote a count: ", event.count);
                    logger.trace(event.raw);
                    printTags(tagRange, event.count.to!string);
                }
            }

            event.count = value.to!int;
            break;

        case "msg-param-sub-plan":
            // The type of subscription plan being used.
            // Valid values: Prime, 1000, 2000, 3000.
            // 1000, 2000, and 3000 refer to the first, second, and third
            // levels of paid subscriptions, respectively (currently $4.99,
            // $9.99, and $24.99).
        case "msg-param-promo-name":
            // Promotion name
            // msg-param-promo-name = Subtember
        case "msg-param-domain":
            // msg-param-domain = owl2018
            // [rewardgift] [#overwatchleague] Asdf [bits]: "A Cheer shared Rewards to 35 others in Chat!" {35}
            // Name of the context?

            version(TwitchWarnings)
            {
                if (event.aux.length)
                {
                    logger.warning(key, " overwrote an aux: ", event.aux);
                    logger.trace(event.raw);
                    printTags(tagRange, event.aux);
                }
            }

            event.aux = value;
            break;

        case "emotes":
            /++ Information to replace text in the message with emote images.
                This can be empty. Syntax:

                <emote ID>:<first index>-<last index>,
                <another first index>-<another last index>/
                <another emote ID>:<first index>-<last index>...

                * emote ID – The number to use in this URL:
                      http://static-cdn.jtvnw.net/emoticons/v1/:<emote ID>/:<size>
                  (size is 1.0, 2.0 or 3.0.)
                * first index, last index – Character indexes. \001ACTION does
                  not count. Indexing starts from the first character that is
                  part of the user’s actual message. See the example (normal
                  message) below.
             +/
            event.emotes = value;
            break;

        case "ban-duration":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // (Optional) Duration of the timeout, in seconds. If omitted,
            // the ban is permanent.
        case "msg-param-viewerCount":
            // RAID; viewer count of raiding channel
            // msg-param-viewerCount = '9'
        case "msg-param-bits-amount":
            //msg-param-bits-amount = '199'
        case "msg-param-mass-gift-count":
            // Number of subs being gifted
        case "msg-param-total":
            // Total amount donated to this charity
        case "msg-param-threshold":
            // (Sent only on bitsbadgetier) The tier of the bits badge the user just earned; e.g. 100, 1000, 10000.
        case "msg-param-streak-months":
        case "msg-param-streak-tenure-months":
        case "msg-param-sub-benefit-end-month":
            /// "...extended their Tier 1 sub to {month}"
            import std.conv : to;

            version(TwitchWarnings)
            {
                if (event.count != 0)
                {
                    import kameloso.printing : printObject;

                    logger.warning(key, " overwrote a count: ", event.count);
                    printObject(event);
                    printTags(tagRange, event.count.to!string);
                }
            }

            event.count = value.to!int;
            break;

        case "msg-param-selected-count":
            // REWARDGIFT; how many users "the Cheer shared Rewards" with
            // "A Cheer shared Rewards to 20 others in Chat!"
        case "msg-param-promo-gift-total":
            // Number of total gifts this promotion
        case "msg-param-sender-count":
            // Number of gift subs a user has given in the channel, on a SUBGIFT event
        case "msg-param-cumulative-months":
            // Total number of months subscribed, over time. Replaces msg-param-months
        case "msg-param-charity-hours-remaining":
            // Number of hours remaining in a charity
            import std.conv : to;

            version(TwitchWarnings)
            {
                if (event.altcount != 0)
                {
                    import kameloso.printing : printObject;

                    logger.warning(key, " overwrote an altcount: ", event.altcount);
                    printObject(event);
                    printTags(tagRange, event.altcount.to!string);
                }
            }

            event.altcount = value.to!int;
            break;

        case "badge-info":
            /+
                Metadata related to the chat badges in the badges tag.

                Currently this is used only for subscriber, to indicate the exact
                number of months the user has been a subscriber. This number is
                finer grained than the version number in badges. For example,
                a user who has been a subscriber for 45 months would have a
                badge-info value of 45 but might have a badges version number
                for only 3 years.

                https://dev.twitch.tv/docs/irc/tags/
             +/
            // As of yet we're not taking into consideration badge versions values.
            // When/if we do, we'll have to make sure this value overwrites the
            // subscriber/version value in the badges tag.
            // For now, ignore, as "subscriber/*" is repeated in badges.
            break;

        case "id":
            // A unique ID for the message.
            event.id = value;
            break;

        // We only need set cases for every known tag if we want to be alerted
        // when we come across unknown ones, which is version TwitchWarnings.
        // As such, version away all the cases from normal builds, and just let
        // them fall to the default.
        version(TwitchWarnings)
        {
            case "msg-param-sub-plan-name":
                // The display name of the subscription plan. This may be a default
                // name or one created by the channel owner.
            case "broadcaster-lang":
                // The chat language when broadcaster language mode is enabled;
                // otherwise, empty. Examples: en (English), fi (Finnish), es-MX
                // (Mexican variant of Spanish).
            case "subs-only":
                // Subscribers-only mode. If enabled, only subscribers and
                // moderators can chat. Valid values: 0 (disabled) or 1 (enabled).
            case "r9k":
                // R9K mode. If enabled, messages with more than 9 characters must
                // be unique. Valid values: 0 (disabled) or 1 (enabled).
            case "emote-sets":
                // A comma-separated list of emotes, belonging to one or more emote
                // sets. This always contains at least 0. Get Chat Emoticons by Set
                // gets a subset of emoticons.
            case "mercury":
                // ?
            case "followers-only":
                // Probably followers only.
            case "room-id":
                // The channel ID.
            case "slow":
                // The number of seconds chatters without moderator privileges must
                // wait between sending messages.
            case "sent-ts":
                // ?
            case "tmi-sent-ts":
                // ?
            case "user":
                // The name of the user who sent the notice.
            case "msg-param-userID":
            case "user-id":
            case "user-ID":
                // The user’s ID.
            case "target-user-id":
                // The target's user ID
            case "rituals":
                /++
                    "Rituals makes it easier for you to celebrate special moments
                    that bring your community together. Say a viewer is checking out
                    a new channel for the first time. After a minute, she’ll have
                    the choice to signal to the rest of the community that she’s new
                    to the channel. Twitch will break the ice for her in Chat, and
                    maybe she’ll make some new friends.

                    Rituals will help you build a more vibrant community when it
                    launches in November."

                    spotted in the wild as = 0
                +/
            case "msg-param-recipient-id":
                // sub gifts
            case "target-msg-id":
                // banphrase
            case "msg-param-profileImageURL":
                // URL link to profile picture.
            case "flags":
                // Unsure.
                // flags =
                // flags = 4-11:P.5,40-46:P.6
            case "mod":
            case "subscriber":
            case "turbo":
                // 1 if the user has a (moderator|subscriber|turbo) badge; otherwise, 0.
                // Deprecated, use badges instead.
            case "user-type":
                // The user’s type. Valid values: empty, mod, global_mod, admin, staff.
                // Deprecated, use badges instead.
            case "msg-param-origin-id":
                // msg-param-origin-id = 6e\s15\s70\s6d\s34\s2a\s7e\s5b\sd9\s45\sd3\sd2\sce\s20\sd3\s4b\s9c\s07\s49\sc4
                // [subgift] [#savjz] sender [SP] (target): "sender gifted a Tier 1 sub to target! This is their first Gift Sub in the channel!" (1000) {1}
            case "msg-param-fun-string":
                // msg-param-fun-string = FunStringTwo
                // [subgift] [#waifugate] AnAnonymousGifter (Asdf): "An anonymous user gifted a Tier 1 sub to Asdf!" (1000) {1}
                // Unsure. Useless.
            case "message-id":
                // message-id = 3
                // WHISPER, rolling number enumerating messages
            case "thread-id":
                // thread-id = 22216721_404208264
                // WHISPER, private message session?
            case "msg-param-cumulative-tenure-months":
                // Ongoing number of subscriptions (in a row)
            case "msg-param-should-share-streak-tenure":
            case "msg-param-should-share-streak":
                // Streak resubs
                // There's no extra field in which to place streak sub numbers
                // without creating a new type, but even then information is lost
                // unless we fall back to auxes of "1000 streak 3".
            case "msg-param-months":
                // DEPRECATED in favour of msg-param-cumulative-months.
                // The number of consecutive months the user has subscribed for,
                // in a resub notice.
            case "msg-param-charity-days-remaining":
                // Number of days remaining in a charity
            case "msg-param-charity-name":
                //msg-param-charity-name = Direct\sRelief
            case "msg-param-charity-learn-more":
                //msg-param-charity-learn-more = https://link.twitch.tv/blizzardofbits
                // Do nothing; everything is done at msg-id charity
            case "message":
                // The message.
            case "number-of-viewers":
                // (Optional) Number of viewers watching the host.
            case "msg-param-min-cheer-amount":
                // REWARDGIFT; of interest?
                // msg-param-min-cheer-amount = '150'
            case "msg-param-ritual-name":
                // msg-param-ritual-name = 'new_chatter'

                // Ignore these events.
                break;
        }

        default:
            version(TwitchWarnings)
            {
                import kameloso.common : logger;
                import kameloso.printing : printObject;
                import kameloso.terminal : TerminalToken;
                import std.algorithm.iteration : joiner;

                logger.warningf("Unknown Twitch tag: %s = %s%c", key, value, cast(char)TerminalToken.bell);
                printObject(event);
                printTags(tagRange);
            }
            break;
        }
    }
}


// onEndOfMotd
/++
 +  Upon having connected, registered and logged onto the Twitch servers,
 +  disable outgoing colours and warn about having a `.` prefix.
 +
 +  Twitch chat doesn't do colours, so ours would only show up like `00kameloso`.
 +  Furthermore, Twitch's own commands are prefixed with a dot `.`, so we can't
 +  use that ourselves.
 +/
@(IRCEvent.Type.RPL_ENDOFMOTD)
void onEndOfMotd(TwitchSupportService service)
{
    import kameloso.common : logger, settings;
    import kameloso.string : beginsWith;

    settings.colouredOutgoing = false;

    if (settings.prefix.beginsWith(".") || settings.prefix.beginsWith("/"))
    {
        string logtint, warningtint;

        version(Colours)
        {
            if (!settings.monochrome)
            {
                import kameloso.logger : KamelosoLogger;

                logtint = (cast(KamelosoLogger)logger).logtint;
                warningtint = (cast(KamelosoLogger)logger).warningtint;
            }
        }

        logger.warningf(`WARNING: A prefix of "%s%s%s" will *not* work ` ~
            `on Twitch servers, as "." and "/" are reserved for Twitch's own commands.`,
            logtint, settings.prefix, warningtint);
    }

    if (service.state.client.colour.length)
    {
        import kameloso.messaging : raw;
        import std.format : format;

        raw(service.state, "PRIVMSG #%s :/color %s"
            .format(service.state.client.nickname, service.state.client.colour));
    }
}


public:


// TwitchSupportService
/++
 +  Twitch-specific service.
 +
 +  Twitch events are initially very basic with only skeletal functionality,
 +  until you enable capabilities that unlock their IRCv3 tags, at which point
 +  events become a flood of information.
 +
 +  This service only post-processes events and doesn't yet act on them in any way.
 +/
final class TwitchSupportService : IRCPlugin
{
private:
    mixin IRCPluginImpl;

    /++
     +  Override `kameloso.plugins.common.IRCPluginImpl.onEvent` and inject a server check, so this
     +  service does nothing on non-Twitch servers. The function to call is
     +  `kameloso.plugins.common.IRCPluginImpl.onEventImpl`.
     +
     +  Params:
     +      event = Parsed `kameloso.irc.defs.IRCEvent` to pass onto
     +          `kameloso.plugins.common.onEventImpl`
     +          after verifying we're on a Twitch server.
     +/
    public void onEvent(const IRCEvent event)
    {
        if (state.client.server.daemon != IRCServer.Daemon.twitch)
        {
            // Daemon known and not Twitch
            return;
        }

        return onEventImpl(event);
    }
}

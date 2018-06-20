/++
 +  The Twitch service postprocesses `kameloso.ircdefs.IRCEvent`s after they are
 +  parsed but before they are sent to the plugins for handling, and deals with
 +  Twitch-specifics. Those include extracting the colour someone's name should
 +  be printed in, their alias/"display name" (generally their nickname
 +  capitalised), converting the event to some event types unique to Twitch,
 +  etc.
 +
 +  It has no bot commands and no event handlers; it only postpocesses events.
 +
 +  It is useless on other servers but crucial on Twitch itself. Even enabled
 +  it won't slow the bot down though, as the vey fist thing it does is to
 +  verify that it is on a Twitch server, and aborts and returns if not.
 +/
module kameloso.plugins.twitch;

version(TwitchSupport):

import kameloso.plugins.common;
import kameloso.ircdefs;

private:


// TwitchSettings
/++
 +  Twitch-specific settings, gathered in a struct.
 +/
struct TwitchSettings
{
    /++
     +  Whether to store the display name colour of users that the server sends,
     +  for use in the `kameloso.plugins.printer.PrinterPlugin` plugin.
     +/
    bool twitchColours = true;
}


// postprocess
/++
 +  Handle Twitch specifics, modifying the `kameloso.ircdefs.IRCEvent` to add
 +  things like `colour` and differentiate between temporary and permanent bans.
 +
 +  Params:
 +      service = Current `TwitchService`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` to modify.
 +/
void postprocess(TwitchService service, ref IRCEvent event)
{
    if (!service.state.bot.server.daemon == IRCServer.Daemon.twitch) return;

    service.parseTwitchTags(event);

    with (event.sender)
    {
        if (nickname.length && !ident.length)
        {
            ident = nickname;
            class_ = IRCUser.Class.anyone;
        }
    }

    if (event.sender.isServer)
    {
        event.sender.badge = "server";

        if (event.type == IRCEvent.Type.CLEARCHAT)
        {
            event.type = event.aux.length ?
                IRCEvent.Type.TWITCH_TEMPBAN : IRCEvent.Type.TWITCH_PERMBAN;
        }
    }
}


// parseTwitchTags
/++
 +  Parses a Twitch event's IRCv3 tags.
 +
 +  The event is passed by ref as many tags neccessitate changes to it.
 +
 +  Params:
 +      service = Current `TwitchService`.
 +      event = Reference to the `kameloso.ircdefs.IRCEvent` whose tags should
 +          be parsed.
 +/
void parseTwitchTags(TwitchService service, ref IRCEvent event)
{
    import kameloso.common : logger;
    import kameloso.irc : decodeIRCv3String;
    import std.algorithm.iteration : splitter;
    import std.conv : to;

    // https://dev.twitch.tv/docs/v5/guides/irc/#twitch-irc-capability-tags

    if (!event.tags.length) return;

    with (IRCEvent)
    foreach (tag; event.tags.splitter(";"))
    {
        import kameloso.string : has, nom;
        immutable key = tag.nom("=");
        immutable value = tag;

        switch (key)
        {
        case "display-name":
            // The user’s display name, escaped as described in the IRCv3 spec.
            // This is empty if it is never set.
            if (event.type != Type.USERSTATE)
            {
                // USERSTATE events are server-sent events that include display-name
                // Exempt them so that the entry for tmi.twitch.tv won't have an alias.
                import kameloso.string : strippedRight;
                event.sender.alias_ = value.has('\\') ? decodeIRCv3String(value).strippedRight : value;
            }
            break;

        case "badges":
            // Comma-separated list of chat badges and the version of each
            // badge (each in the format <badge>/<version>, such as admin/1).
            // Valid badge values: admin, bits, broadcaster, global_mod,
            // moderator, subscriber, staff, turbo.
            if (!value.length) break;

            // Assume the first badge is the most prominent one.
            // Seems to be the case
            string slice = value;
            event.sender.badge = slice.nom('/');
            break;

        case "mod":
        case "subscriber":
        case "turbo":
            // 1 if the user has a (moderator|subscriber|turbo) badge;
            // otherwise, 0.
            if (value == "0") break;

            if (!event.sender.badge.length)
            {
                logger.errorf("PANIC! %s yet no previous badge!", key);
            }
            break;

        case "ban-duration":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // (Optional) Duration of the timeout, in seconds. If omitted,
            // the ban is permanent.
            event.aux = value;
            break;

        case "user-type":
            // The user’s type. Valid values: empty, mod, global_mod, admin, staff.
            // The broadcaster can have any of these.
            if (!value.length) break;
            if (!event.sender.badge.length)
            {
                logger.errorf("PANIC! %s yet no previous badge!", value);
            }
            break;

        case "system-msg":
        case "ban-reason":
            // @ban-duration=<ban-duration>;ban-reason=<ban-reason> :tmi.twitch.tv CLEARCHAT #<channel> :<user>
            // The moderator’s reason for the timeout or ban.
            // system-msg: The message printed in chat along with this notice.
            import kameloso.string : strippedRight;
            if (!event.content.length) event.content = decodeIRCv3String(value).strippedRight;
            break;

        case "emote-only":
            if (value == "0") break;
            if (event.type == Type.CHAN) event.type = Type.EMOTE;
            break;

        case "msg-id":
            // The type of notice (not the ID) / A message ID string.
            // Can be used for i18ln. Valid values: see
            // Msg-id Tags for the NOTICE Commands Capability.
            // https://dev.twitch.tv/docs/irc#msg-id-tags-for-the-notice-commands-capability
            // https://swiftyspiffy.com/TwitchLib/Client/_msg_ids_8cs_source.html

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
            case "host_on":
                event.type = Type.HOSTSTART;
                break;

            case "host_off":
            case "host_target_went_offline":
                event.type = Type.HOSTEND;
                break;

            case "sub":
                event.type = Type.TWITCH_SUB;
                event.num = 1;  // "one-month resub"
                break;

            case "resub":
                event.type = Type.TWITCH_RESUB;
                break;

            case "subgift":
                // [21:33:48] msg-param-recipient-display-name = 'emilypiee'
                // [21:33:48] msg-param-recipient-id = '125985061'
                // [21:33:48] msg-param-recipient-user-name = 'emilypiee'
                event.type = Type.TWITCH_SUBGIFT;
                break;

            case "ritual":
                // unhandled message: ritual
                event.type = Type.TWITCH_RITUAL;
                break;

            case "rewardgift":
                //msg-param-bits-amount = '199'
                //msg-param-min-cheer-amount = '150'
                //msg-param-selected-count = '60'
                event.type = Type.TWITCH_REWARDGIFT;
                break;

            case "purchase":
                //msg-param-asin = 'B07DBTZZTH'
                //msg-param-channelID = '17337557'
                //msg-param-crateCount = '0'
                //msg-param-imageURL = 'https://images-na.ssl-images-amazon.com/images/I/31PzvL+AidL.jpg'
                //msg-param-title = 'Speed\s&\sMomentum\sCrate\s(Steam\sVersion)'
                //msg-param-userID = '182815893'
                //[usernotice] tmi.twitch.tv [#drdisrespectlive]: "Purchased Speed & Momentum Crate (Steam Version) in channel."
                event.type = Type.TWITCH_PURCHASE;
                break;

            case "raid":
                //display-name=VHSGlitch
                //login=vhsglitch
                //msg-id=raid
                //msg-param-displayName=VHSGlitch
                //msg-param-login=vhsglitch
                //msg-param-viewerCount=9
                //system-msg=9\sraiders\sfrom\sVHSGlitch\shave\sjoined\n!
                event.type = Type.TWITCH_RAID;
                break;

            case "ban_success":
            case "timeout_success":
            case "unban_success":
                // Generic Twitch server reply.
                event.type = Type.TWITCH_REPLY;
                event.aux = value;
                break;

            case "already_banned":
            case "already_emote_only_on":
            case "already_emote_only_off":
            case "already_r9k_on":
            case "already_r9k_off":
            case "already_subs_on":
            case "already_subs_off":
            case "bad_host_hosting":
            case "bad_unban_no_ban":
            case "unrecognized_cmd":
            case "unsupported_chatrooms_cmd":
            case "msg_room_not_found":
            case "no_permission":
            case "raid_error_self":
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
                // Generic Twitch settings change
                event.type = Type.TWITCH_SETTING;
                event.aux = value;
                break;

            case "hosts_remaining":
            case "msg_channel_suspended":
            case "color_changed":
            case "room_mods":
            case "raid_notice_mature":
                // Twitch notices; what type should they be?
                event.aux = value;
                break;

            default:
                logger.warning("Unknown Twitch msg-id: ", value);
                break;
            }
            break;

        case "msg-param-recipient-display-name":
            event.target.alias_ = value;
            break;

        case "msg-param-recipient-user-name":
            event.target.nickname = value;
            break;

        case "msg-param-displayName":
            // RAID; sender alias and thus raiding channel cased
            event.sender.alias_ = value;
            break;

        case "msg-param-login":
        case "login":
            // RAID; real sender nickname and thus raiding channel lowercased
            // also PURCHASE. The sender's user login (real nickname)
            event.sender.nickname = value;
            break;

        case "msg-param-months":
            // The number of consecutive months the user has subscribed for,
            // in a resub notice.
            event.num = value.to!uint;
            break;

        case "msg-param-sub-plan":
            // The type of subscription plan being used.
            // Valid values: Prime, 1000, 2000, 3000.
            // 1000, 2000, and 3000 refer to the first, second, and third
            // levels of paid subscriptions, respectively (currently $4.99,
            // $9.99, and $24.99).
            event.aux = value;
            break;

        case "color":
            // Hexadecimal RGB colour code. This is empty if it is never set.
            if (service.twitchSettings.twitchColours && value.length)
            {
                event.sender.colour = value[1..$];
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
            event.type = Type.TWITCH_CHEER;
            event.aux = value;
            break;

        case "msg-param-ritual-name":
            // msg-param-ritual-name = 'new_chatter'
            // [ritual] tmi.twitch.tv [#couragejd]: "@callmejosh15 is new here. Say hello!"
            event.aux = value;
            break;

        case "msg-param-bits-amount":
            //msg-param-bits-amount = '199'
            event.aux = value;
            break;

        case "msg-param-title":
            //msg-param-title = 'Speed\s&\sMomentum\sCrate\s(Steam\sVersion)'
            event.aux = decodeIRCv3String(value);
            break;

        case "msg-param-crateCount":
            // PURCHASE, no idea
        case "msg-param-sender-count":
            // Number of gift subs a user has given in the channel, on a SUBGIFT event
        case "msg-param-selected-count":
            // REWARDGIFT; of interest?
            event.num = value.to!uint;
            break;

        case "msg-param-asin":
            // PURCHASE
            //msg-param-asin = 'B07DBTZZTH'
        case "msg-param-channelID":
            // PURCHASE
            //msg-param-channelID = '17337557'
        case "msg-param-imageURL":
            // PURCHASE
            //msg-param-imageURL = 'https://images-na.ssl-images-amazon.com/images/I/31PzvL+AidL.jpg'
        case "msg-param-min-cheer-amount":
            // REWARDGIFT; of interest?
            // msg-param-min-cheer-amount = '150'
        case "msg-param-sub-plan-name":
            // The display name of the subscription plan. This may be a default
            // name or one created by the channel owner.
        case "broadcaster-lang":
            // The chat language when broadcaster language mode is enabled;
            // otherwise, empty. Examples: en (English), fi (Finnish), es-MX
            //(Mexican variant of Spanish).
        case "subs-only":
            // Subscribers-only mode. If enabled, only subscribers and
            // moderators can chat. Valid values: 0 (disabled) or 1 (enabled).
        case "r9k":
            // R9K mode. If enabled, messages with more than 9 characters must
            // be unique. Valid values: 0 (disabled) or 1 (enabled).
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
        case "id":
            // A unique ID for the message.
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

            // Ignore these events.
            break;

        case "msg-param-viewerCount":
            // RAID; viewer count of raiding channel
            // msg-param-viewerCount = '9'
            event.num = value.to!uint;
            break;

        case "message":
            // The message.
        case "number-of-viewers":
            // (Optional) Number of viewers watching the host.
        default:
            // Verbosely
            logger.warningf("Unknown Twitch tag: %s = %s", key, value);
            break;
        }
    }
}


public:


// TwitchService
/++
 +  Twitch-specific service.
 +
 +  Twitch events are initially very basic with only skeletal functionality,
 +  until you enable capabilites that unlock their `IRCv3` tags, at which point
 +  events become a flood of information.
 +
 +  This service only postprocesses events and doesn't yet act on them in any
 +  way.
 +/
final class TwitchService : IRCPlugin
{
    /// All Twitch service options gathered.
    @Settings TwitchSettings twitchSettings;

    mixin IRCPluginImpl;
}

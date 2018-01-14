module kameloso.plugins.persistence;

import kameloso.plugins.common;
import kameloso.ircdefs;

private:


// postprocess
/++
 +  Hijacks a ref `IRCEvent` after parsing and fleshes out the `event.sender`
 +  and/or `event.target` fields, so that things like account names that are
 +  only sent sometimes carry over.
 +/
void postprocess(PersistenceService service, ref IRCEvent event)
{
    import kameloso.common : meldInto;
    import std.range : only;
    import std.typecons : Flag, No, Yes;

    if (event.type == IRCEvent.Type.QUIT) return;

    foreach (user; only(&event.sender, &event.target))
    {
        if (!user.nickname.length) continue;

        if (auto stored = user.nickname in service.state.users)
        {
            // Record WHOIS if we have new account information, except if it's
            // the bot's (which we doesn't care about)
            if ((user.account.length && !stored.account.length) ||
                (event.type == IRCEvent.Type.RPL_WHOISACCOUNT))
            {
                import std.datetime.systime : Clock;
                user.lastWhois = Clock.currTime.toUnixTime;
            }

            // Meld into the stored user, and store the union in the event
            (*user).meldInto!(Yes.overwrite)(*stored);
            *user = *stored;
        }
        else
        {
            // New entry
            service.state.users[event.sender.nickname] = *user;
        }
    }
}


// onQuit
/++
 +  Removes a user's `IRCUser` entry from a the `state.users` list upon them
 +  disconnecting.
 +/
@(IRCEvent.Type.QUIT)
void onQuit(PersistenceService service, const IRCEvent event)
{
    service.state.users.remove(event.sender.nickname);
}


// onNick
/++
 +  Update the entry of someone in the `users` array to when they change
 +  nickname, point to the new `IRCUser`.
 +
 +  Removes the old entry.
 +/
@(IRCEvent.Type.NICK)
void onNick(PersistenceService service, const IRCEvent event)
{
    with (service.state)
    {
        if (auto stored = event.sender.nickname in users)
        {
            users[event.target.nickname] = *stored;
            users[event.target.nickname].nickname = event.target.nickname;
            users.remove(event.sender.nickname);
        }
        else
        {
            users[event.target.nickname] = event.sender;
            users[event.target.nickname].nickname = event.target.nickname;
        }
    }
}


// onPing
/++
 +  Rehash the internal `state.users` associative array of `IRCUser`s, once
 +  every `hoursBetweenRehashes` hours.
 +
 +  We ride the periodicity of `PING` to get a natural cadence without
 +  having to resort to timed `Fiber`s.
 +
 +  The number of hours is so far hardcoded but can be made configurable if
 +  there's a use-case for it.
 +/
@(IRCEvent.Type.PING)
void onPing(PersistenceService service)
{
    import std.datetime.systime : Clock;

    const hour = Clock.currTime.hour;

    enum hoursBetweenRehashes = 12;  // also see UserAwareness

    with (service)
    {
        /// Once every few hours, rehash the `users` array.
        if ((hoursBetweenRehashes > 0) && (hour == rehashCounter))
        {
            rehashCounter = (rehashCounter + hoursBetweenRehashes) % 24;
            state.users.rehash();
        }
    }
}


public:


// PersistenceService
/++
 +  The Persistence service melds new `IRCUser`s (from postprocessing new
 +  `IRCEvent`s) with old records of themselves,
 +
 +  Sometimes the only bit of information about a sender (or target) embedded in
 +  an `IRCEvent` may be his/her nickname, even though the event before detailed
 +  everything, even including their account name. With this service we aim to
 +  complete such `IRCUser` entries with the union of everything we know from
 +  previous events.
 +
 +  It only needs part of `UserAwareness` for minimal bookkeeping, not the full
 +  package, so we only copy/paste the relevant bits to stay slim.
 +/
final class PersistenceService : IRCPlugin
{
    mixin IRCPluginImpl;
}

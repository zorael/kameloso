module kameloso.plugins.common;

import kameloso.ircdefs;

import std.concurrency;
import std.typecons : Flag, No;

interface IRCPlugin {}

class WHOISRequest
{
    IRCEvent event;
}

class WHOISRequestImpl(F, Payload) : WHOISRequest
{
    this(Payload, IRCEvent, PrivilegeLevel, F) {}

    void toString(void delegate()) const
    {
        import std.format;
        "[%s] @ %s".format(event);
    }
}

WHOISRequest whoisRequest(F, Payload)(Payload payload, IRCEvent event,
    PrivilegeLevel privilegeLevel, F fn)
{
    return new WHOISRequestImpl!(F, Payload)(payload, event, privilegeLevel, fn);
}

struct IRCPluginState
{
    IRCBot bot;
    Tid mainThread;
}

enum FilterResult
{
    fail,
    pass,
    whois
}

enum PrivilegeLevel
{
    anyone,
    whitelist,
    admin,
    ignore,
}

FilterResult filterUser(IRCPluginState, IRCEvent event)
{
    immutable user = event.sender;
    if (user.account) return FilterResult.whois;
    return FilterResult.fail;
}

template IRCPluginImpl(string module_ = __MODULE__)
{
    IRCPluginState privateState;

    void onEvent(IRCEvent event)
    {
        mixin("static import thisModule = " ~ module_ ~ ";");

        import std.meta : AliasSeq, Filter, templateNot, templateOr;
        import std.traits : getSymbolsByUDA, isSomeFunction, getUDAs;

        alias isAwarenessFunction = templateOr!();
        alias isNormalPluginFunction = templateNot!isAwarenessFunction;

        alias funs = Filter!(isSomeFunction, getSymbolsByUDA!(thisModule, IRCEvent.Type));

        enum Next
        {
            continue_
        }

        Next handle(alias fun)(IRCEvent)
        {
            IRCEvent mutEvent;

            enum privilegeLevel = getUDAs!(fun, PrivilegeLevel)[0];

            with (PrivilegeLevel)
            final switch (privilegeLevel)
            {
            case whitelist:
            case admin:
                immutable result = privateState.filterUser(mutEvent);

                with (FilterResult)
                final switch (result)
                {
                case pass:
                    break;

                case whois:
                    this.doWhois(this, mutEvent, privilegeLevel, &fun);
                    break;

                case fail:
                    break;
                }

                break;
            case anyone:
            case ignore:
                break;
            }
            return Next.continue_;
        }

        alias pluginFuns = Filter!(isNormalPluginFunction, funs);

        void tryCatchHandle(funlist...)(IRCEvent)
        {
            foreach (fun; funlist)
            {
                try handle!fun(event);
                catch (Exception e) {}
            }
        }

        tryCatchHandle!pluginFuns(event);
    }

    ref IRCBot bot()
    {
        return privateState.bot;
    }

    ref IRCPluginState state()
    {
        return this.privateState;
    }
}

template MessagingProxy()
{
    import std.typecons : Flag, No;
    static import kameloso.messaging;

    void join(Flag!"quiet" quiet = No.quiet)(string channel)
    {
        kameloso.messaging.join!quiet(state.mainThread, channel);
    }
}

void doWhois(F, Payload)(IRCPlugin, Payload payload, IRCEvent event,
    PrivilegeLevel privilegeLevel, F fn)
{
    whoisRequest(payload, event, privilegeLevel, fn);
}

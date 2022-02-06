
module kameloso.plugins.common.awareness;

version(WithPlugins):

private:

import kameloso.plugins.common.core;
import dialect.defs;
import std.typecons : Flag, No, Yes;

public:

@safe:




enum Awareness
{
    
    setup,

    
    early,

    
    late,

    
    cleanup,
}




mixin template MinimalAuthentication(Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import kameloso.plugins.common.awareness;
    private import dialect.defs : IRCEvent;
    private import lu.traits : MixinConstraints, MixinScope;

    

    static if (__traits(compiles, .hasMinimalAuthentication))
    {
        private import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("MinimalAuthentication", module_));
    }
    else
    {
        
        package enum hasMinimalAuthentication = true;
    }


    
}




void onMinimalAuthenticationAccountInfoTarget(IRCPlugin plugin, const ref IRCEvent event) @system
{
    
}




void onMinimalAuthenticationUnknownCommandWHOIS(IRCPlugin plugin, const ref IRCEvent event) @system
{
    import kameloso.plugins.common.mixins : Repeater;

    if (event.aux != "WHOIS") return;

    
    
    
    

    mixin Repeater;

    foreach (replaysForNickname; plugin.state.replays)
    {
        foreach (replay; replaysForNickname)
        {
            repeat(replay);
        }
    }

    plugin.state.replays.clear();
    plugin.state.hasReplays = false;
}




mixin template UserAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import kameloso.plugins.common.awareness;
    private import dialect.defs : IRCEvent;
    private import lu.traits : MixinConstraints, MixinScope;

    

    static if (__traits(compiles, .hasUserAwareness))
    {
        private import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("UserAwareness", module_));
    }
    else
    {
        
        package enum hasUserAwareness = true;
    }

    static if (!__traits(compiles, .hasMinimalAuthentication))
    {
        mixin MinimalAuthentication!(debug_, module_);
    }


@safe:

    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    
}




void onUserAwarenessQuit(IRCPlugin plugin, const ref IRCEvent event)
{
    
}




version(WithPlugins)
mixin template ChannelAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import kameloso.plugins.common.awareness;
    private import dialect.defs : IRCEvent;
    private import lu.traits : MixinConstraints, MixinScope;

    

    static if (__traits(compiles, .hasChannelAwareness))
    {
        private import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("ChannelAwareness", module_));
    }
    else
    {
        
        package enum hasChannelAwareness = true;
    }

    


@safe:

    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    


    
    
    
}




void onChannelAwarenessSelfjoin(IRCPlugin plugin, const ref IRCEvent event)
{
    
}




void onChannelAwarenessQuit(IRCPlugin plugin, const ref IRCEvent event)
{
    
}




void onChannelAwarenessTopic(IRCPlugin plugin, const ref IRCEvent event)
{
    
}




void onChannelAwarenessModeLists(IRCPlugin plugin, const ref IRCEvent event)
{
    
}




void onChannelAwarenessChannelModeIs(IRCPlugin plugin, const ref IRCEvent event)
{
    
}




version(WithPlugins)
version(TwitchSupport)
mixin template TwitchAwareness(ChannelPolicy channelPolicy = ChannelPolicy.home,
    Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    private import kameloso.plugins.common.awareness;
    private import dialect.defs : IRCEvent;
    private import lu.traits : MixinConstraints, MixinScope;

    

    static if (__traits(compiles, .hasTwitchAwareness))
    {
        private import std.format : format;
        static assert(0, "Double mixin of `%s` in `%s`"
            .format("TwitchAwareness", module_));
    }
    else
    {
        
        package enum hasTwitchAwareness = true;
    }

    


@safe:

    
    
    


    
    
    
}




version(TwitchSupport)
void onTwitchAwarenessSenderCarryingEvent(IRCPlugin plugin, const ref IRCEvent event)
{
    
}





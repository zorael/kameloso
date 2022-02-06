
module kameloso.plugins.common.mixins;

import std.typecons : Flag, No, Yes;

mixin template Repeater(Flag!"debug_" debug_ = No.debug_,
    string module_ = __MODULE__)
{
    import kameloso.plugins.common.core : Repeat, Replay;
    import dialect.defs : IRCUser;
    import lu.traits : MixinConstraints, MixinScope;
    import std.conv : text;
    import std.traits : isSomeFunction;

    

    

    static if (__traits(compiles, plugin))
    {
        alias context = plugin;
        enum contextName = "plugin";
    }
    else static if (__traits(compiles, service))
    {
        alias context = service;
        enum contextName = "service";
    }
    else
    {
        static assert(0, "`Repeater` should be mixed into the context " ~
            "of an event handler. (Could not access variables named neither " ~
            "`plugin` nor `service` from within `" ~ __FUNCTION__ ~ "`)");
    }


    
    
    version(ExplainRepeat)
    void explainRepeat(const Repeat repeat)
    {
        import kameloso.common : Tint, logger;
        import lu.conv : Enum;
        import lu.string : beginsWith;

        enum pattern = "%s%s%s %s repeating %1$s%5$s%3$s-level event (invoking %1$s%6$s%3$s) " ~
            "based on WHOIS results: user %1$s%7$s%3$s is %1$s%8$s%3$s class";

        immutable caller = repeat.replay.caller.beginsWith("kameloso.plugins.") ?
            repeat.replay.caller[17..$] :
            repeat.replay.caller;

        logger.logf(pattern,
            Tint.info, context.name, Tint.log, contextName,
            repeat.replay.permissionsRequired,
            caller,
            repeat.replay.event.sender.nickname,
            repeat.replay.event.sender.class_);
    }


    
    
    version(ExplainRepeat)
    void explainRefuse(const Repeat repeat)
    {
        
    }


    
    
    void repeaterDelegate()
    {
        
    }

    
    void repeat(Replay replay)
    {
        import kameloso.plugins.common.misc : repeat;
        context.repeat(&repeaterDelegate, replay);
    }
}

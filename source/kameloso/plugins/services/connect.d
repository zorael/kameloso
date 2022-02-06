
module kameloso.plugins.services.connect;

version(WithPlugins):
version(WithConnectService):

private:

import kameloso.plugins.common.core;
import kameloso.common : Tint, logger;
import kameloso.messaging;
import kameloso.thread : ThreadMessage;
import dialect.defs;
import std.typecons : Flag, No, Yes;




@Settings struct ConnectSettings
{
private:
    import lu.uda : CannotContainComments, Separator, Unserialisable;

public:
    
    bool regainNickname = true;

    
    bool joinOnInvite = false;

    
    @Unserialisable bool sasl = true;

    
    bool exitOnSASLFailure = false;

    
    @Separator(";;")
    @CannotContainComments
    string[] sendAfterConnect;
}



enum Progress
{
    notStarted, 
    inProgress, 
    finished,   
}





void onSelfpart(ConnectService service, const ref IRCEvent event)
{
    
}





void onToConnectType(ConnectService service, const ref IRCEvent event)
{
    
}





void onPing(ConnectService service, const ref IRCEvent event)
{
    import std.concurrency : prioritySend;

    immutable target = event.content.length ? event.content : event.sender.address;
    service.state.mainThread.prioritySend(ThreadMessage.Pong(), target);
}




void tryAuth(ConnectService service)
{
    
}





void onAuthEnd(ConnectService service, const ref IRCEvent event)
{
    
}





void onISUPPORT(ConnectService service, const ref IRCEvent event)
{
    
}





void onReconnect(ConnectService service)
{
    import std.concurrency : send;

    logger.info("Reconnecting upon server request.");
    service.state.mainThread.send(ThreadMessage.Reconnect());
}





public:




final class ConnectService : IRCPlugin
{
private:
    import core.time : seconds;

    
    ConnectSettings connectSettings;

    
    static immutable authenticationGracePeriod = 15.seconds;

    
    static immutable capLSTimeout = 15.seconds;

    
    static immutable nickRegainPeriodicity = 600.seconds;

    
    enum appendAltNickSignSeparately = false;

    
    Progress authentication;

    
    Progress saslExternal;

    
    Progress registration;

    
    Progress capabilityNegotiation;

    
    bool issuedNICK;

    
    string renameDuringRegistration;

    
    bool joinedChannels;

    
    bool serverSupportsWHOIS = true;

    
    uint requestedCapabilitiesRemaining;

    mixin IRCPluginImpl;
}

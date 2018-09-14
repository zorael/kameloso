
module kameloso.common;

CoreSettings settings;





struct CoreSettings
{
    
    bool ipv6 ;

}




struct Client
{
    import kameloso.connection ;

    
    

    
    Connection conn;

    
    import kameloso.irc ;
    IRCParser parser;

bool* abort;

}




enum Next
{
    returnFailure, 
}




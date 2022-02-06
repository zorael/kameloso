
module dialect.parsing;

import dialect.defs;
unittest
{
    
    

    

    {
(":adams.freenode.net 001 kameloso^ "             ":Welcome to the freenode Internet Relay Chat Network kameloso^");
        {
("kameloso^");
("Welcome to the freenode Internet Relay Chat Network kameloso^");
        }
    }
}




unittest
{
    {
"ERROR :Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)";
(("Closing Link: 81-233-105-62-no80.tbcn.telia.com (Quit: kameloso^)"));
    }
}




unittest
{
    {
":zorael!~NaN@some.address.org PRIVMSG kameloso :this is fake";
    }

    {
":NickServ!NickServ@services. NOTICE kameloso :This nickname is registered.";
    }

    {
":kameloso^^!~NaN@C2802314.E23AD7D8.E9841504.IP JOIN :#flerrp";
(("kameloso^^"));
    }

    {
":Q!TheQBot@CServe.quakenet.org NOTICE kameloso :You are now logged in as kameloso.";
    }
}




unittest
{
    {
"421 kameloso åäö :Unknown command";
    }

    {
"353 kameloso = #garderoben :@kameloso'";
    }

    {
"PRIVMSG kameloso^ :test test content";
    }

}




unittest
{
"kameloso^";
    {
"kameloso^ :+i";
    }
    {
"kameloso^ :-i";
    }
    {
"kameloso^ :+abc";
    }
    {
"kameloso^ :-bx";
    }
}




struct IRCParser
{
    
    IRCClient client;

    
    IRCServer server;

}


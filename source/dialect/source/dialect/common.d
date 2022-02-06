
module dialect.common;

import dialect.defs;
import lu.string ;

@safe:




auto typenumsOf() {
}




unittest
{
(`kameloso\sjust\ssubscribed\swith\sa\s`         `$4.99\ssub.\skameloso\ssubscribed\sfor\s40\smonths\sin\sa\srow!`);
(("kameloso just subscribed with a $4.99 sub. "         "kameloso subscribed for 40 months in a row!"));

}




unittest
{
    {
(            "NOTICE kameloso :You are now logged in as kameloso.");
    }
    {
(            "NOTICE kameloso :This nickname is registered.");
    }

    {
(            "NOTICE kameloso^^ :nick, type /msg NickServ IDENTIFY password. Otherwise,");
    }
}




unittest
{
    [
        "kameloso"        "kameloso^"    ];

}




bool isValidNicknameCharacter(ubyte c) pure {
    switch (c)
    default:
        return false;
}


unittest
{
    {
"@kameloso";
(("kameloso"));
    }

    {
"kameloso";
(("kameloso"));
    }

    {
"@+kameloso";
(("kameloso"));
    }
}




unittest
{
    {
"@+kameloso";
(("kameloso"));
    }
}




unittest
{
    {
("kameloso!~NaN@aasdf.freenode.org");
    }

    {
("kameloso zorael");
("kameloso");
    }

}




enum IRCControlCharacter
{
    colour      }




unittest
{
("kameloso!NaN@wopkfoewopk.com");

("kameloso!*@*");
}




bool isValidHostmask(string , IRCServer ) {
    string slice ;  

    immutable address = slice;
    return address == "*";
}


unittest
{
    {
"kameloso!~kameloso@2001*";
    }
}




interface Postprocessor
{
}

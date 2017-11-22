module kameloso.main;

import kameloso.common;
import kameloso.irc;

import std.concurrency;


void main(string[] args)
{
    IRCBot bot;
    // Print the current settings to show what's going on.
    printObjects(bot, bot.server, settings);
}

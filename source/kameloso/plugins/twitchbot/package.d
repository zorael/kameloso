/++
 +  Package for the TwitchBot plugin modules.
 +/
module kameloso.plugins.twitchbot;

version(WithPlugins):
version(TwitchSupport):
version(WithTwitchBotPlugin):

public import kameloso.plugins.twitchbot.base;
public import kameloso.plugins.twitchbot.api;
public import kameloso.plugins.twitchbot.timers;

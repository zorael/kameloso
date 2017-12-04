module kameloso.plugins;

import std.meta : AliasSeq;

/// Publically import all plugins so that only kameloso.plugins need be imported.
public import kameloso.plugins.admin;
public import kameloso.plugins.chatbot;
public import kameloso.plugins.common;
public import kameloso.plugins.connect;
public import kameloso.plugins.ctcp;
public import kameloso.plugins.notes;
public import kameloso.plugins.printer;
public import kameloso.plugins.sedreplace;
public import kameloso.plugins.twitch;
public import kameloso.plugins.seen;

version(Posix)
{
    // Implicitly enabled if imported
    public import kameloso.plugins.pipeline;
}

version(Webtitles)
{
    // Implicitly enabled if imported
    public import kameloso.plugins.webtitles;
    public import kameloso.plugins.bashquotes;
}

/// Add plugins to this list to enable them
public alias EnabledPlugins = AliasSeq!(
    PrinterPlugin,
    ConnectPlugin,
    AdminPlugin,
    ChatbotPlugin,
    NotesPlugin,
    SedReplacePlugin,
    CTCPPlugin,
    TwitchPlugin,
    SeenPlugin,
);

module kameloso.plugins;

/// Publically import all plugins so that only kameloso.plugins need be imported.
public import kameloso.plugins.common;

public import kameloso.plugins.connect;
public import kameloso.plugins.printer;
//public import kameloso.plugins.pinger;
public import kameloso.plugins.admin;
public import kameloso.plugins.chatbot;
public import kameloso.plugins.notes;
public import kameloso.plugins.sedreplace;

version(Webtitles)
{
    public import kameloso.plugins.webtitles;
}

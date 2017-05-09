module kameloso.plugins.sedreplace;

import kameloso.plugins.common;
import kameloso.constants;
import kameloso.common;
import kameloso.irc;

import std.stdio : writeln, writefln;
import std.datetime;
import std.concurrency;
import std.regex;

private:

IrcPluginState state;
Line[string] prevlines;


enum replaceTimeoutSeconds = 60;
enum sedPattern = `^s/([^/]+)/([^/]*)/(g?)$`;
//enum sedPattern2 = `^s#([^#]+)#([^#]*)#(g?)$`;
static sedRegex = ctRegex!sedPattern;


struct Line
{
    string content;
    SysTime when;
}


string sedReplace(const string originalLine, const string expression)
{
    string result = originalLine;

    foreach (hit; expression.matchAll(sedRegex))
    {
        const changeThis = hit[1];
        const toThis = hit[2];
        const globalFlag = (hit[3].length > 0);

        if (globalFlag)
        {
            writeln("global!");
            result = result.replaceAll(changeThis.regex, toThis);
        }
        else
        {
            writeln("not global...");
            result = result.replaceFirst(changeThis.regex, toThis);
        }
    }

    return result;
}


@(Label("chan"))
@(IrcEvent.Type.CHAN)
void onMessage(const IrcEvent event)
{
    import kameloso.stringutils;
    import std.string : strip;
    import std.format : format;

    const stripped = event.content.strip;

    if (!stripped.beginsWith("s/"))
    {
        Line line;
        line.content = stripped;
        line.when = Clock.currTime;
        prevlines[event.sender] = line;
        return;
    }

    if (auto line = event.sender in prevlines)
    {
        if ((Clock.currTime - line.when) > replaceTimeoutSeconds.seconds) return;

        const result = line.content.sedReplace(event.content);
        if ((result == event.content) || !result.length) return;

        state.mainThread.send(ThreadMessage.Sendline(),
            "PRIVMSG %s :%s | %s".format(event.channel, event.sender, result));

        prevlines.remove(event.sender);
    }
}


mixin basicEventHandlers;
mixin onEventImpl!__MODULE__;


public:

final class SedReplacePlugin : IrcPlugin
{
    mixin IrcPluginBasics;
}

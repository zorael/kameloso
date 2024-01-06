/++
    Functions related to importing and embedding custom emotes.

    See_Also:
        [kameloso.plugins.twitch.emotes.bttv]
        [kameloso.plugins.twitch.emotes.ffz]
        [kameloso.plugins.twitch.emotes.seventv]

    Copyright: [JR](https://github.com/zorael)
    License: [Boost Software License 1.0](https://www.boost.org/users/license.html)

    Authors:
        [JR](https://github.com/zorael)
 +/
module kameloso.plugins.twitch.emotes;

version(TwitchSupport):
version(WithTwitchPlugin):

private:

import kameloso.plugins.twitch : TwitchPlugin;

import kameloso.common : logger;
import std.typecons : Flag, No, Yes;
import core.thread : Fiber;

public:


// importCustomEmotes
/++
    Fetches custom BetterTTV, FrankerFaceZ and 7tv emotes via API calls.

    If a channel name is supplied, the emotes are imported for that channel.
    If not, global ones are imported. An `id` can only be supplied if
    a `channelName` is also supplied.

    Params:
        plugin = The current [TwitchPlugin].
        channelName = (Optional) Name of channel to import emotes for.
        id = (Optional, mandatory if `channelName` supplied) Twitch numeric ID of channel.
 +/
void importCustomEmotes(
    TwitchPlugin plugin,
    const string channelName = string.init,
    const uint id = 0)
in (Fiber.getThis(), "Tried to call `importCustomEmotes` from outside a fiber")
in (((channelName.length && id) ||
    (!channelName.length && !id)),
    "Tried to import custom channel-specific emotes with insufficient arguments")
{
    alias GetEmoteFun = void function(
        TwitchPlugin,
        ref bool[dstring],
        const uint,
        const string);

    static struct EmoteImport
    {
        GetEmoteFun fun;
        string name;
        uint failures;
    }

    enum failureReportPeriodicity = 5;
    enum giveUpThreshold = 15;  // multiple of failureReportPeriodicity

    EmoteImport[] emoteImports;
    bool[dstring]* customEmotes;
    bool atLeastOneImportFailed;
    version(assert) bool addedSomething;

    if (channelName.length)
    {
        import kameloso.plugins.twitch.emotes.bttv : getBTTVEmotes;
        import kameloso.plugins.twitch.emotes.ffz : getFFZEmotes;
        import kameloso.plugins.twitch.emotes.seventv : get7tvEmotes;

        // Channel-specific emotes
        customEmotes = channelName in plugin.customEmotesByChannel;

        if (!customEmotes)
        {
            // Initialise it
            //plugin.customEmotesByChannel[channelName] = new bool[dstring];  // fails with older compilers
            plugin.customEmotesByChannel[channelName][dstring.init] = false;
            customEmotes = channelName in plugin.customEmotesByChannel;
            (*customEmotes).remove(dstring.init);
        }

        emoteImports =
        [
            EmoteImport(&getBTTVEmotes, "BetterTTV"),
            EmoteImport(&getFFZEmotes, "FrankerFaceZ"),
            EmoteImport(&get7tvEmotes, "7tv"),
        ];
    }
    else
    {
        import kameloso.plugins.twitch.emotes.bttv : getBTTVEmotesGlobal;
        import kameloso.plugins.twitch.emotes.ffz : getFFZEmotesGlobal;
        import kameloso.plugins.twitch.emotes.seventv : get7tvEmotesGlobal;

        // Global emotes
        customEmotes = &plugin.customGlobalEmotes;

        emoteImports =
        [
            EmoteImport(&getBTTVEmotesGlobal, "BetterTTV"),
            EmoteImport(&getFFZEmotesGlobal, "FrankerFaceZ"),
            EmoteImport(&get7tvEmotesGlobal, "7tv"),
        ];
    }

    // Loop until the array is exhausted. Remove completed and/or failed imports.
    while (emoteImports.length)
    {
        import std.algorithm.mutation : SwapStrategy, remove;
        import core.memory : GC;

        GC.disable();
        scope(exit) GC.enable();

        size_t[] toRemove;

        foreach (immutable i, ref emoteImport; emoteImports)
        {
            immutable lengthBefore = customEmotes.length;

            try
            {
                emoteImport.fun(plugin, *customEmotes, id, __FUNCTION__);

                if (plugin.state.settings.trace)
                {
                    immutable deltaLength = (customEmotes.length - lengthBefore);

                    if (deltaLength)
                    {
                        version(assert) addedSomething = true;

                        if (channelName.length)
                        {
                            enum pattern = "Successfully imported <l>%s</> emotes " ~
                                "for channel <l>%s</> (<l>%d</>)";
                            logger.infof(pattern, emoteImport.name, channelName, deltaLength);
                        }
                        else
                        {
                            enum pattern = "Successfully imported global <l>%s</> emotes (<l>%d</>)";
                            logger.infof(pattern, emoteImport.name, deltaLength);
                        }
                    }
                    /*else
                    {
                        if (channelName.length)
                        {
                            enum pattern = "No <l>%s</> emotes for channel <l>%s</>.";
                            logger.infof(pattern, emoteImport.name, channelName);
                        }
                        else
                        {
                            enum pattern = "No global <l>%s</> emotes.";
                            logger.infof(pattern, emoteImport.name);
                        }
                    }*/
                }

                // Success; flag it for deletion
                toRemove ~= i;
                continue;
            }
            catch (Exception e)
            {
                ++emoteImport.failures;

                // Occasionally report failures
                if ((emoteImport.failures % failureReportPeriodicity) == 0)
                {
                    if (channelName.length)
                    {
                        enum pattern = "Failed to import <l>%s</> emotes for channel <l>%s</>.";
                        logger.warningf(pattern, emoteImport.name, channelName);
                    }
                    else
                    {
                        enum pattern = "Failed to import global <l>%s</> emotes.";
                        logger.warningf(pattern, emoteImport.name);
                    }

                    version(PrintStacktraces)
                    {
                        import std.stdio : stdout, writeln;
                        writeln(e);
                        stdout.flush();
                    }
                }

                if (emoteImport.failures >= giveUpThreshold)
                {
                    // Failed too many times; flag it for deletion
                    toRemove ~= i;
                    atLeastOneImportFailed = true;
                    continue;
                }
            }
        }

        foreach_reverse (immutable i; toRemove)
        {
            // Remove completed and/or successively failed imports
            emoteImports = emoteImports.remove!(SwapStrategy.unstable)(i);
        }

        if (emoteImports.length)
        {
            import kameloso.plugins.common.delayawait : delay;
            import core.time : seconds;

            // Still some left; repeat on remaining imports after a delay
            static immutable retryDelay = 5.seconds;
            delay(plugin, retryDelay, Yes.yield);
        }
    }

    version(assert)
    {
        if (addedSomething)
        {
            enum message = "Custom emotes were imported but the resulting AA is empty";
            assert(customEmotes.length, message);
        }
    }

    if (atLeastOneImportFailed)
    {
        enum message = "Some custom emotes failed to import.";
        logger.error(message);
    }

    if (customEmotes.length)
    {
        customEmotes.rehash();
    }
    else
    {
        if (channelName.length)
        {
            // Nothing imported, may as well remove the AA
            plugin.customEmotesByChannel.remove(channelName);
        }
    }
}


// embedCustomEmotes
/++
    Embeds custom emotes into the `emotes` string passed by reference,
    so that the [kameloso.plugins.printer.PrinterPlugin|PrinterPlugin] can
    highlight `content` with colours.

    This is called in [postprocess].

    Params:
        content = Content string.
        emotes = Reference string into which to save the emote list.
        customEmotes = `bool[dstring]` associative array of channel-specific custom emotes.
        customGlobalEmotes = `bool[dstring]` associative array of global custom emotes.
 +/
void embedCustomEmotes(
    const string content,
    ref string emotes,
    const bool[dstring] customEmotes,
    const bool[dstring] customGlobalEmotes)
{
    import lu.string : strippedRight;
    import std.algorithm.comparison : among;
    import std.array : Appender;
    import std.conv : to;
    import std.string : indexOf;

    static Appender!(char[]) sink;

    if (!customEmotes.length && !customGlobalEmotes.length) return;

    scope(exit)
    {
        if (sink.data.length)
        {
            emotes ~= sink.data;
            sink.clear();
        }
    }

    if (sink.capacity == 0) sink.reserve(64);  // guesstimate

    immutable dline = content.strippedRight.to!dstring;
    ptrdiff_t pos = dline.indexOf(' ');
    dstring previousEmote;  // mutable
    size_t prev;

    static bool isEmoteCharacter(const dchar dc)
    {
        // Unsure about '-' and '(' but be conservative and keep
        return (
            ((dc >= dchar('a')) && (dc <= dchar('z'))) ||
            ((dc >= dchar('A')) && (dc <= dchar('Z'))) ||
            ((dc >= dchar('0')) && (dc <= dchar('9'))) ||
            dc.among!(dchar(':'), dchar(')'), dchar('-'), dchar('(')));
    }

    void appendEmote(const dstring dword)
    {
        import std.array : replace;
        import std.format : formattedWrite;

        enum pattern = "/%s:%d-%d";
        immutable slicedPattern = (emotes.length || sink.data.length) ?
            pattern :
            pattern[1..$];
        immutable dwordEscaped = dword.replace(dchar(':'), dchar(';'));
        immutable end = (pos == -1) ?
            dline.length :
            pos;
        sink.formattedWrite(slicedPattern, dwordEscaped, prev, end-1);
        previousEmote = dword;
    }

    void checkWord(const dstring dword)
    {
        import std.format : formattedWrite;

        // Micro-optimise a bit by skipping AA lookups of words that are unlikely to be emotes
        if ((dword.length > 1) &&
            isEmoteCharacter(dword[$-1]) &&
            isEmoteCharacter(dword[0]))
        {
            // Can reasonably be an emote
        }
        else
        {
            // Can reasonably not
            return;
        }

        if (dword == previousEmote)
        {
            enum pattern = ",%d-%d";
            immutable end = (pos == -1) ?
                dline.length :
                pos;
            sink.formattedWrite(pattern, prev, end-1);
            return;  // cannot return non-void from `void` function
        }

        if ((dword in customGlobalEmotes) || (dword in customEmotes))
        {
            return appendEmote(dword);
        }
    }

    if (pos == -1)
    {
        // No bounding space, check entire (one-word) line
        return checkWord(dline);
    }

    while (true)
    {
        if (pos > prev)
        {
            checkWord(dline[prev..pos]);
        }

        prev = (pos + 1);
        if (prev >= dline.length) return;

        pos = dline.indexOf(' ', prev);
        if (pos == -1)
        {
            return checkWord(dline[prev..$]);
        }
    }

    assert(0, "Unreachable");
}

///
unittest
{
    bool[dstring] customEmotes =
    [
        ":tf:"d : true,
        "FrankerZ"d : true,
        "NOTED"d : true,
    ];

    bool[dstring] customGlobalEmotes =
    [
        "KEKW"d : true,
        "NotLikeThis"d : true,
        "gg"d : true,
    ];

    {
        enum content = "come on its easy, now rest then talk talk more left, left, " ~
            "right re st, up, down talk some rest a bit talk poop  :tf:";
        string emotes;
        embedCustomEmotes(content, emotes, customEmotes, customGlobalEmotes);
        enum expectedEmotes = ";tf;:113-116";
        assert((emotes == expectedEmotes), emotes);
    }
    {
        enum content = "NOTED  FrankerZ  NOTED NOTED    gg";
        string emotes;
        embedCustomEmotes(content, emotes, customEmotes, customGlobalEmotes);
        enum expectedEmotes = "NOTED:0-4/FrankerZ:7-14/NOTED:17-21,23-27/gg:32-33";
        assert((emotes == expectedEmotes), emotes);
    }
    {
        enum content = "No emotes here KAPPA";
        string emotes;
        embedCustomEmotes(content, emotes, customEmotes, customGlobalEmotes);
        enum expectedEmotes = string.init;
        assert((emotes == expectedEmotes), emotes);
    }
}

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

import core.thread.fiber : Fiber;
import core.time : seconds;

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
    import kameloso.common : logger;
    import kameloso.plugins.common.scheduling : delay;

    alias GetEmoteFun = uint function(
        TwitchPlugin,
        bool[string]*,
        const uint,
        const string);

    static struct EmoteImport
    {
        GetEmoteFun fun;
        string name;
        uint failures;
    }

    enum failureReportPoint = 5;
    enum giveUpThreshold = failureReportPoint * 3;

    EmoteImport[] emoteImports;
    bool[string] collectedEmotes;
    bool atLeastOneImportFailed;
    version(assert) bool addedSomething;

    if (channelName.length)
    {
        import kameloso.plugins.twitch.emotes.bttv : getBTTVEmotes;
        import kameloso.plugins.twitch.emotes.ffz : getFFZEmotes;
        import kameloso.plugins.twitch.emotes.seventv : get7tvEmotes;

        // Channel-specific emotes
        auto customChannelEmotes = channelName in plugin.customChannelEmotes;

        if (!customChannelEmotes)
        {
            // Initialise it
            plugin.customChannelEmotes[channelName] = TwitchPlugin.CustomChannelEmotes.init;
            customChannelEmotes = channelName in plugin.customChannelEmotes;
        }

        customChannelEmotes.channelName = channelName;
        customChannelEmotes.id = id;

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
        emoteImports =
        [
            EmoteImport(&getBTTVEmotesGlobal, "BetterTTV"),
            EmoteImport(&getFFZEmotesGlobal, "FrankerFaceZ"),
            EmoteImport(&get7tvEmotesGlobal, "7tv"),
        ];
    }

    // Delay importing just a bit to cosmetically stagger the terminal output
    static immutable initialDelay = 2.seconds;
    delay(plugin, initialDelay, yield: true);

    // Loop until the array is exhausted. Remove completed and/or failed imports.
    while (emoteImports.length)
    {
        import kameloso.plugins.common.scheduling : delay;
        import std.algorithm.mutation : SwapStrategy, remove;
        import core.memory : GC;
        import core.time : seconds;

        size_t[] toRemove;

        foreach (immutable i, ref emoteImport; emoteImports)
        {
            GC.disable();
            scope(exit) GC.enable();

            try
            {
                immutable numAdded = emoteImport.fun(
                    plugin,
                    &collectedEmotes,
                    id,
                    __FUNCTION__);

                if (plugin.state.settings.trace)
                {
                    if (numAdded)
                    {
                        version(assert) addedSomething = true;

                        if (channelName.length)
                        {
                            enum pattern = "Successfully imported <l>%s</> emotes " ~
                                "for channel <l>%s</> (<l>%d</>)";
                            logger.infof(pattern, emoteImport.name, channelName, numAdded);
                        }
                        else
                        {
                            enum pattern = "Successfully imported global <l>%s</> emotes (<l>%d</>)";
                            logger.infof(pattern, emoteImport.name, numAdded);
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

                // Report failure once but keep trying
                if (emoteImport.failures == failureReportPoint)
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
                else if (emoteImport.failures >= giveUpThreshold)
                {
                    // Failed too many times; flag it for deletion
                    toRemove ~= i;
                    atLeastOneImportFailed = true;
                    continue;  // skip the delay below
                }

                static immutable retryOnErrorDelay = 3.seconds;
                delay(plugin, retryOnErrorDelay, yield: true);
            }
        }

        foreach_reverse (immutable i; toRemove)
        {
            // Remove completed and/or successively failed imports
            emoteImports = emoteImports.remove!(SwapStrategy.unstable)(i);
        }
    }

    version(assert)
    {
        if (addedSomething)
        {
            enum message = "Custom emotes were imported but the resulting AA is empty";
            assert(collectedEmotes.length, message);
        }
    }

    if (atLeastOneImportFailed)
    {
        enum message = "Some custom emotes failed to import.";
        logger.error(message);
    }

    if (channelName.length)
    {
        import std.conv : to;
        auto channelEmotes = channelName in plugin.customChannelEmotes;
        channelEmotes.emotes = collectedEmotes.to!(bool[dstring]);
    }
    else
    {
        import lu.meld : meldInto;
        import std.conv : to;

        auto dstringAA = collectedEmotes.to!(bool[dstring]);
        dstringAA.meldInto(plugin.customGlobalEmotes);
    }

    /*else
    {
        if (channelName.length)
        {
            // Nothing imported, may as well remove the entry
            plugin.customChannelEmotes.remove(channelName);
        }
    }*/
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

    static Appender!(dchar[]) dsink;

    if (!customEmotes.length && !customGlobalEmotes.length) return;

    scope(exit)
    {
        if (dsink[].length)
        {
            emotes ~= dsink[].to!string;
            dsink.clear();
        }
    }

    if (dsink.capacity == 0) dsink.reserve(64);  // guesstimate

    immutable dline = content.strippedRight.to!dstring;
    ptrdiff_t spacePos = dline.indexOf(' ');
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

        enum pattern = "/%s:%d-%d"d;
        immutable slicedPattern = (emotes.length || dsink[].length) ?
            pattern :
            pattern[1..$];
        immutable dwordEscaped = dword.replace(dchar(':'), dchar(';'));
        immutable end = (spacePos == -1) ?
            dline.length :
            spacePos;
        dsink.formattedWrite(slicedPattern, dwordEscaped, prev, end-1);
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
            enum pattern = ",%d-%d"d;
            immutable end = (spacePos == -1) ?
                dline.length :
                spacePos;
            dsink.formattedWrite(pattern, prev, end-1);
            return;  // cannot return non-void from `void` function
        }

        if ((dword in customGlobalEmotes) || (dword in customEmotes))
        {
            return appendEmote(dword);
        }
    }

    if (spacePos == -1)
    {
        // No bounding space, check entire (one-word) line
        return checkWord(dline);
    }

    while (true)
    {
        if (spacePos > prev)
        {
            checkWord(dline[prev..spacePos]);
        }

        prev = (spacePos + 1);
        if (prev >= dline.length) return;

        spacePos = dline.indexOf(' ', prev);
        if (spacePos == -1)
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


// baseDelayBetweenImports
/++
    The base delay between importing custom emotes, in seconds.

    This is used to stagger the imports so that they don't all happen at once.
 +/
static immutable baseDelayBetweenImports = 1.seconds;

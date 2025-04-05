/++
    Functions related to importing and embedding custom emotes.

    See_Also:
        [kameloso.plugins.twitch],
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


// importCustomEmotesImpl
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
void importCustomEmotesImpl(
    TwitchPlugin plugin,
    const string channelName = string.init,
    const ulong id = 0)
in (Fiber.getThis(), "Tried to call `importCustomEmotes` from outside a fiber")
in (((channelName.length && id) ||
    (!channelName.length && !id)),
    "Tried to import custom channel-specific emotes with insufficient arguments")
{
    import kameloso.common : logger;
    import kameloso.plugins.common.scheduling : delay;

    alias GetEmoteFun = size_t function(
        TwitchPlugin,
        bool[string]*,
        const ulong,
        const string);

    static struct EmoteImport
    {
        GetEmoteFun fun;
        string name;
        uint failures;
    }

    enum failureReportPoint = 3;
    enum giveUpThreshold = failureReportPoint + 2;

    EmoteImport[] emoteImports;
    bool[string] collectedEmotes;

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
    delay(plugin, Delays.initialDelayBeforeImports, yield: true);

    void reportSuccess(const string emoteImportName, const size_t numAdded)
    {
        if (numAdded)
        {
            if (channelName.length)
            {
                enum pattern = "Successfully imported <l>%s</> emotes " ~
                    "for channel <l>%s</> (<l>%d</>)";
                logger.infof(pattern, emoteImportName, channelName, numAdded);
            }
            else
            {
                enum pattern = "Successfully imported global <l>%s</> emotes (<l>%d</>)";
                logger.infof(pattern, emoteImportName, numAdded);
            }
        }
        /*else
        {
            if (channelName.length)
            {
                enum pattern = "No <l>%s</> emotes for channel <l>%s</>.";
                logger.infof(pattern, emoteImportName, channelName);
            }
            else
            {
                enum pattern = "No global <l>%s</> emotes.";
                logger.infof(pattern, emoteImportName);
            }
        }*/
    }

    void reportFailure(const string emoteImportName)
    {
        if (channelName.length)
        {
            enum pattern = "Failed to import <l>%s</> emotes for channel <l>%s</>.";
            logger.warningf(pattern, emoteImportName, channelName);
        }
        else
        {
            enum pattern = "Failed to import global <l>%s</> emotes.";
            logger.warningf(pattern, emoteImportName);
        }
    }

    // Loop until the array is exhausted. Remove completed and/or failed imports.
    while (emoteImports.length)
    {
        import kameloso.plugins.common.scheduling : delay;
        import mir.serde : SerdeException;
        import core.memory : GC;

        size_t[] toRemove;
        toRemove.reserve(emoteImports.length);

        foreach (immutable i, ref emoteImport; emoteImports)
        {
            GC.disable();
            scope(exit) GC.enable();

            if (i > 0)
            {
                // Delay between imports, but skip the delay for the first one
                delay(plugin, Delays.delayBetweenImports, yield: true);
            }

            try
            {
                immutable numAdded = emoteImport.fun(
                    plugin,
                    &collectedEmotes,
                    id,
                    __FUNCTION__);

                if (plugin.state.coreSettings.trace)
                {
                    reportSuccess(emoteImport.name, numAdded);
                }

                // Success; flag it for deletion
                toRemove ~= i;
                continue;
            }
            catch (SerdeException _)
            {
                if (plugin.state.coreSettings.trace)
                {
                    reportFailure(emoteImport.name);
                }

                // Unlikely to succeed later; flag it for deletion
                toRemove ~= i;
                continue;
            }
            catch (Exception e)
            {
                ++emoteImport.failures;

                // Report failure once but keep trying
                if (emoteImport.failures == failureReportPoint)
                {
                    reportFailure(emoteImport.name);

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
                    continue;  // skip the delay below
                }

                delay(plugin, Delays.extraDelayAfterError, yield: true);
            }
        }

        foreach_reverse (immutable i; toRemove)
        {
            import std.algorithm.mutation : SwapStrategy, remove;
            // Remove completed and/or repeatedly failing imports
            emoteImports = emoteImports.remove!(SwapStrategy.unstable)(i);
        }
    }

    if (channelName.length)
    {
        import std.conv : to;
        auto channelEmotes = channelName in plugin.customChannelEmotes;
        channelEmotes.emotes = collectedEmotes.to!(bool[dstring]);
        channelEmotes.emotes.rehash();
    }
    else
    {
        import lu.meld : meldInto;
        import std.conv : to;

        auto dstringAA = collectedEmotes.to!(bool[dstring]);
        dstringAA.meldInto(plugin.customGlobalEmotes);
        plugin.customGlobalEmotes.rehash();
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
        import std.algorithm.comparison : among;
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


// Delays
/++
    Delays used in the emote import process.
 +/
struct Delays
{
    /++
        The initial delay before importing custom emotes.
        This is mostly to stagger the terminal output.
     +/
    static immutable initialDelayBeforeImports = 2.seconds;

    /++
        The base delay between importing custom emotes.
        This is used to stagger the imports so that they don't all happen at once.
     +/
    static immutable delayBetweenImports = 1.seconds;

    /++
        The extra delay to add after an error has occurred.
        This is used to prevent hammering the API with requests.

        The final duration will be `extraDelayAfterError + delayBetweenImports`.
     +/
    alias extraDelayAfterError = delayBetweenImports;
}

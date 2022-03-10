# kameloso [![Linux/macOS/Windows](https://img.shields.io/github/workflow/status/zorael/kameloso/D?logo=github&style=flat&maxAge=3600)](https://github.com/zorael/kameloso/actions?query=workflow%3AD) [![Linux](https://img.shields.io/circleci/project/github/zorael/kameloso/master.svg?logo=circleci&style=flat&maxAge=3600)](https://circleci.com/gh/zorael/kameloso) [![Windows](https://img.shields.io/appveyor/ci/zorael/kameloso/master.svg?logo=appveyor&style=flat&maxAge=3600)](https://ci.appveyor.com/project/zorael/kameloso) [![Commits since last release](https://img.shields.io/github/commits-since/zorael/kameloso/v3.0.0-rc.1.svg?logo=github&style=flat&maxAge=3600)](https://github.com/zorael/kameloso/compare/v3.0.0-rc.1...master)

**kameloso** is an IRC bot.

## Current functionality includes:

* chat monitoring in bedazzling colours (or mesmerising monochrome)
* automatic mode sets (e.g. auto `+o` on join)
* logs
* reporting titles of pasted URLs, YouTube video information fetch
* **sed**-replacement of messages (`s/this/that/` substitution)
* saving notes to offline users that get played back when they come online
* channel polls, `!seen`, counters, stopwatches
* works on **Twitch** with some common Twitch bot features
* [more random stuff and gimmicks](https://github.com/zorael/kameloso/wiki/Current-plugins)

All of the above are plugins and can be disabled at runtime or omitted from compilation entirely. It is modular and easy to extend. A skeletal Hello World plugin is [25 lines of code](source/kameloso/plugins/hello.d).

Testing is primarily done on [**Libera.Chat**](https://libera.chat) and on [**Twitch**](https://dev.twitch.tv/docs/irc/guide) servers, so support and coverage is best there.

**Please report bugs. Unreported bugs can only be fixed by accident.**

# tl;dr

```
-n       --nickname Nickname
-s         --server Server address [irc.libera.chat]
-P           --port Server port [6667]
-A        --account Services account name
-p       --password Services account password
           --admins Administrators' services accounts, comma-separated
-H   --homeChannels Home channels to operate in, comma-separated
-C  --guestChannels Non-home channels to idle in, comma-separated
       --monochrome Use monochrome output
-w           --save Write configuration to file
```

Pre-compiled binaries for Windows and Linux can be found under [Releases](https://github.com/zorael/kameloso/releases).

```sh
$ dub run kameloso -- --server irc.libera.chat --guestChannels "#d"

# alternatively
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
$ dub build
$ ./kameloso --server irc.libera.chat --guestChannels "#d"
```

If there's anyone talking it should show up on your screen.

---

# Table of contents

* [Getting started](#getting-started)
  * [Prerequisites](#prerequisites)
  * [Downloading](#downloading)
  * [Compiling](#compiling)
    * [Build configurations](#build-configurations)
* [How to use](#how-to-use)
  * [Configuration](#configuration)
    * [Command-line arguments](#command-line-arguments)
    * [Display settings](#display-settings)
    * [Other files](#other-files)
  * [Example use](#example-use)
    * [Online help and commands](#online-help-and-commands)
    * [**Except nothing happens**](#except-nothing-happens)
  * [Twitch](#twitch)
    * [Caveats](#caveats)
    * [Example configuration](#example-configuration)
    * [Streamer assistant bot](#streamer-assistant-bot)
  * [Further help](#further-help)
* [Known issues](#known-issues)
  * [Windows](#windows)
* [Roadmap](#roadmap)
* [Built with](#built-with)
* [License](#license)
* [Acknowledgements](#acknowledgements)

---

# Getting started

Grab a pre-compiled binary from under [Releases](https://github.com/zorael/kameloso/releases); alternatively, download the source and compile it yourself.

## Prerequisites

**kameloso** is written in [**D**](https://dlang.org). It can be built using the reference compiler [**dmd**](https://dlang.org/download.html), which compiles very fast; and the LLVM-based [**ldc**](https://github.com/ldc-developers/ldc/releases), which is slower at compiling but produces faster code. See [here](https://wiki.dlang.org/Compilers) for an overview of the available compiler vendors.

You need one based on D version **2.084** or later (January 2019). For **ldc** this is version **1.14**. Sadly, the stable release of the GCC-based [**gdc**](https://gdcproject.org/downloads) is currently based on version **2.076** and is thus too old to be used.

If your repositories (or other software sources) don't have compilers new enough, you can use the official [`install.sh`](https://dlang.org/install.html) installation script to download current ones, or any version of choice.

The package manager [**dub**](https://code.dlang.org) is used to facilitate compilation and dependency management. On Windows it comes bundled in the compiler archive, while on Linux it may need to be installed separately. Refer to your repositories.

## Downloading

```sh
$ git clone https://github.com/zorael/kameloso.git
```

It can also be downloaded as a [`.zip` archive](https://github.com/zorael/kameloso/archive/master.zip).

## Compiling

```sh
$ dub build
```

This will compile the bot in the default *debug* mode, which adds some extra code and debugging symbols. You can automatically omit these and add some optimisations by building it in *release* mode with `dub build -b release`. Mind that build times will increase accordingly. Refer to the output of `dub build --help` for more build types.

### Build configurations

There are several configurations in which the bot may be built.

* `application`, base configuration
* `twitch`, additionally includes Twitch chat support and the Twitch streamer plugin
* `dev`, all-inclusive development build equalling everything available, including things like more detailed error messages

All configurations come in a `-lowmem` variant (e.g. `application-lowmem`, `twitch-lowmem`, ...) that lowers compilation memory at the cost of increasing compilation time, but so far they only work with **ldc**. (bug [#20699](https://issues.dlang.org/show_bug.cgi?id=20699))

List configurations with `dub build --print-configs`. You can specify which to compile with the `-c` switch. Not supplying one will make it build the default `application` configuration.

```sh
$ dub build -c twitch
```

> If you want to customise your own build to only compile the plugins you want to use, see the larger `versions` lists in `dub.sdl`. Simply add or delete a character from the line corresponding to the plugin(s) you want to omit (thus invalidating the version identifier). Mind that disabling any of the "*service*" plugins may break the bot in subtle ways.

# How to use

## Configuration

The bot ideally wants the account name of one or more administrators of the bot, and/or one or more home channels to operate in. Without either it's just a read-only log bot, which is incidentally also fine. To define these you can either specify them on the command line, with flags listed by calling the program with `--help`, or generate a configuration file and input them there.

```sh
$ ./kameloso --save
```

A new `kameloso.conf` will be created in a directory dependent on your platform.

* **Linux** and other Posix: `~/.config/kameloso` (alternatively where `$XDG_CONFIG_HOME` points)
* **Windows**: `%APPDATA%\kameloso`
* **macOS**: `$HOME/Library/Application Support/kameloso`

Open the file in a normal text editor. If you have your system file associations set up to open `*.conf` files in such, you can pass `--gedit` to attempt to open it in a graphical editor, or `--edit` to open it in your default terminal one (as defined in the `$EDITOR` environment variable).

### Command-line arguments

Settings provided at the command line override any such already defined in your configuration file. If you specify some and also add `--save`, it will apply the changes to your file in-place.

```sh
$ ./kameloso \
    --server irc.libera.chat \
    --nickname "kameloso" \
    --admins "you,friend" \
    --homeChannels "#mychannel,#elsewhere" \
    --guestChannels "#d,##networking" \
    --save

[12:34:56] Configuration written to /home/user/.config/kameloso/kameloso.conf
```

Other settings not specified at invocations of `--save` keep their values. Mind however that the configuration file is parsed and *rewritten*, so any comments or invalid entries in it will be silently removed.

### Display settings

If you have a bright terminal background, text may be difficult to read, depending on your terminal emulator. If so, pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses the full range of [8-colour ANSI](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more colours are too dark or bright even with the right `brightTerminal` setting, please refer to your terminal appearance settings. Colouring might not work well with greyish theming.

An alternative is to disable colours entirely with `--monochrome`.

### Other files

More server-specific resource files will be created the first time you connect to a server. These include `users.json`, in which you whitelist which accounts get to access the bot's features on a per-channel basis. Where these are stored also depends on platform; in the case of **macOS** and **Windows** they will be put in server-split subdirectories of the same directory as the configuration file, listed above. On **Linux** and other Posix, under `~/.local/share/kameloso` (or wherever `$XDG_DATA_HOME` points to).

## Example use

```
      you joined #channel
 kameloso sets mode +o you

      you | I am a fish
      you | s/fish/snek/
 kameloso | you | I am a snek

      you | !quote kameloso I am a snek
 kameloso | Quote saved. (1 on record)
      you | !quote kameloso
 kameloso | kameloso | I am a snek

      you | !seen MrOffline
 kameloso | I last saw MrOffline 1 hour and 34 minutes ago.

      you | !note MrOffline About the thing you mentioned, yeah no
 kameloso | Note added.
MrOffline joined #channel
 kameloso | MrOffline! you left note 28 minutes ago: About the thing you mentioned, yeah no

      you | !operator add bob
 kameloso | Added BOB as an operator in #channel.
      you | !whitelist add alice
 kameloso | Added Alice as a whitelisted user in #channel.
      you | !blacklist del steve
 kameloso | Removed steve as a blacklisted user in #channel.

      you | !automode add ray +o
 kameloso | Automode modified! ray on #channel: +o
      ray joined #channel
 kameloso sets mode +o ray

      you | !oneliner add info @$nickname: for more information just use Google
 kameloso | Oneliner !info added.
      you | !oneliner add vods See https://twitch.tv/zorael/videos for $streamer's on-demand videos (stored temporarily)
 kameloso | Oneliner !vods added.
      you | !oneliner add source I am $bot. Peruse my source at https://github.com/zorael/kameloso
 kameloso | Oneliner !source added.
      you | !info
 kameloso | @you: for more information just use Google
      you | !vods
 kameloso | See https://twitch.tv/zorael/videos for Channel's on-demand videos (stored temporarily)
      you | !commands
 kameloso | Available commands: !info, !vods, !source
      you | !oneliner del vods
 kameloso | Oneliner !vods removed.

      you | !poll 60 snek snik
 kameloso | Voting commenced! Please place your vote for one of: snik, snek (60 seconds)
      BOB | snek
    Alice | snek
      ray | snik
 kameloso | Voting complete, results:
 kameloso | snek : 2 (66.6%)
 kameloso | snik : 1 (33.3%)

      you | https://github.com/zorael/kameloso
 kameloso | [github.com] GitHub - zorael/kameloso: IRC bot
      you | https://youtu.be/ykj3Kpm3O0g
 kameloso | [youtube.com] Uti Vår Hage - Kamelåså (HD) (uploaded by Prebstaroni)

<context: playing a video game>
      you | !counter add deaths
 kameloso | Counter deaths added! Access it with !deaths.
      you | !deaths+
 kameloso | deaths +1! Current count: 1
      you | !deaths+
 kameloso | deaths +1! Current count: 2
      you | !deaths
 kameloso | Current deaths count: 2
      you | !deaths=0
 kameloso | deaths count assigned to 0!

      you | !stopwatch start
 kameloso | Stopwatch started!
      you | !stopwatch
 kameloso | Elapsed time: 18 minutes and 42 seconds
      you | !stopwatch stop
 kameloso | Stopwatch stopped after 1 hour, 48 minutes and 10 seconds.
```

### Online help and commands

Use the `!help` command for a summary of available bot commands, and `!help [plugin] [command]` for a brief description of a specific one. The shorthand `!help !command` also works.

The command **prefix** (here `!`) is configurable; refer to your generated configuration file. Common alternatives are `.` and `~`, making it `.note` and `~quote` respectively.

```ini
[Core]
prefix                  "!"
```

It can technically be any string and not just one character. It may include spaces if enclosed within quotes, like `"please "` (making it `please note`, `please quote`, ...). Additionally, prefixing commands with the bot's nickname also works, as in `kameloso: seen MrOffline`. This is to be able to disambiguate between several bots in the same channel. Moreover, some administrative commands only work when called this way.

### **Except nothing happens**

Before allowing *anyone* to trigger any restricted functionality, the bot will query the server for what services account the accessing user is logged onto. For full administrative privileges you will need to be logged in with an account listed in the `admins` field in the configuration file, while other users may be defined in your `users.json` file. If a user is not logged onto services it is considered as not being uniquely identifiable.

> In the case of *hostmasks mode*, the above still applies but "accounts" are inferred from hostmasks. See the **Admin** plugin `!hostmask` command (and the `hostmasks.json` file) for how to map hostmasks to would-be accounts. Hostmasks are a weaker solution to user identification but not all servers may offer services. See [the wiki entry on hostmasks](https://github.com/zorael/kameloso/wiki/On-servers-without-services-(e.g.-no-NickServ)) for more information.

## Twitch

To connect to Twitch servers you must first build a configuration that includes support for it, which is currently either `twitch` or `dev`.

You must also supply an [OAuth token](https://en.wikipedia.org/wiki/OAuth) **pass** (not password). These authorisation tokens are unique to your user paired with an application. As such, you need a new one for each and every program you want to access Twitch with.

Run the bot with `--set twitchbot.keygen` to start the captive process of generating one. It will open a browser window, in which you are asked to log onto Twitch *on Twitch's own servers*. Verify this by checking the page address; it should end with `.twitch.tv`, with the little lock symbol showing the connection is secure.

> Note: At no point is the bot privy to your login credentials! The logging-in is wholly done on Twitch's own servers, and no information is sent to any third parties. The code that deals with this is open for audit; [`generateKey` in `twitchbot/keygen.d`](source/kameloso/plugins/twitchbot/keygen.d).

After entering your login and password and clicking **Authorize**, you will be redirected to an empty "`this site can't be reached`" or "`unable to connect`" page. Copy the URL address of it and paste it into the terminal, when asked. It will parse the address, extract your authorisation token, and offer to save it to your configuration file.

If you prefer to generate the token manually, here is the URL you need to follow. The only thing the generation process does is open it for you, and help with saving the end key to disk.

```
https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=tjyryd2ojnqr8a51ml19kn1yi2n0v1&redirect_uri=http://localhost&scope=channel:moderate+chat:edit+chat:read+whispers:edit+whispers:read&force_verify=true
```

### Caveats

Most of the bot's features will work on Twitch. The **Automode** plugin is an exception (as Twitch uses badges instead of modes), and it will auto-disable itself appropriately.

That said, in many ways Twitch chat does not behave as a full IRC server. Most common IRC commands go unrecognised. Joins and parts are not always advertised, and when they are they come in delayed batches and cannot be relied upon. You can also only join channels for which a corresponding Twitch user account exists.

### Example configuration

```ini
[IRCClient]
nickname            botaccount
user                ignored
realName            likewise

[IRCBot]
#account
#password
pass                personaloauthauthorisationtoken
admins              mainaccount
homeChannels        #mainaccount,#botaccount
guestChannels       #streamer1,#streamer2,#streamer3

[IRCServer]
address             irc.chat.twitch.tv
port                6667
```

The Twitch SSL port is **6697** (or **443**).

See [the wiki page on Twitch](https://github.com/zorael/kameloso/wiki/Twitch) for more information.

### Streamer assistant bot

The streamer bot is enabled by default when built, and can be disabled in the configuration file under the `[TwitchBot]` section. If the section doesn't exist, ensure that you have built a configuration with Twitch support, then regenerate the file with `--save`. Even if enabled it disables itself on non-Twitch servers.

```sh
$ ./kameloso --set twitchbot.enabled=false --save
```

Properly enabled and assuming a prefix of `!`, commands to test are:

* `!start`, `!uptime`, `!stop`
* `!timer`
* `!followage`
* `!shoutout`

...alongside `!operator`, `!whitelist`, `!blacklist`, `!oneliner`, `!poll`, `!counter`, `!stopwatch`, and other non-Twitch-specific commands.

> Note: dot `.` and slash `/` prefixes will not work on Twitch.

**Please make the bot a moderator to prevent its messages from being as aggressively rate-limited.**

## Further help

For more information and help, first see [the wiki](https://github.com/zorael/kameloso/wiki).

If you still can't find what you're looking for, or if you have suggestions on how to improve the bot, you can...

* ...start a thread under [Discussions](https://github.com/zorael/kameloso/discussions)
* ...file a [GitHub issue](https://github.com/zorael/kameloso/issues/new)

# Known issues

## Windows

If SSL doesn't work at all, you may simply be missing the required libraries. Download and install **OpenSSL** "Light" from [here](https://slproweb.com/products/Win32OpenSSL.html), and opt to install to system directories when asked.

Even with SSL seemingly properly set up you may see errors of *"Peer certificates cannot be authenticated with given CA certificates"*. If this happens, download this [`cacert.pem`](https://curl.haxx.se/ca/cacert.pem) file, place it somewhere reasonable, and edit your configuration file to point to it; `caBundleFile` under `[Connection]`.

# Roadmap

* pipedream zero: **no compiler segfaults** ([#18026](https://issues.dlang.org/show_bug.cgi?id=18026), [#20562](https://issues.dlang.org/show_bug.cgi?id=20562))
* pipedream: DCC
* non-blocking FIFO
* more pairs of eyes

# Built with

* [**D**](https://dlang.org)
* [`dub`](https://code.dlang.org)
* [`dialect`](https://github.com/zorael/dialect) ([dub](https://code.dlang.org/packages/dialect))
* [`lu`](https://github.com/zorael/lu) ([dub](https://code.dlang.org/packages/lu))
* [`requests`](https://github.com/ikod/dlang-requests) ([dub](https://code.dlang.org/packages/requests))
* [`arsd`](https://github.com/adamdruppe/arsd) ([dub](https://code.dlang.org/packages/arsd-official))

# License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

# Acknowledgements

* [Kamelåså](https://youtu.be/ykj3Kpm3O0g)
* [`README.md` template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [ikod](https://github.com/ikod) for [`dlang-requests`](https://github.com/ikod/dlang-requests)
* [Adam D. Ruppe](https://github.com/adamdruppe) for [`arsd`](https://github.com/adamdruppe/arsd)
* [`#d` on libera.chat](irc://irc.libera.chat:6697/#d)
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on libera.chat](irc://irc.libera.chat:6667/#ircdocs)

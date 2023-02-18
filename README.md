# kameloso [![Linux/macOS/Windows](https://img.shields.io/github/actions/workflow/status/zorael/kameloso/d.yml?branch=master)](https://github.com/zorael/kameloso/actions?query=workflow%3AD) [![Linux](https://img.shields.io/circleci/project/github/zorael/kameloso/master.svg?logo=circleci&style=flat&maxAge=3600)](https://circleci.com/gh/zorael/kameloso) [![Windows](https://img.shields.io/appveyor/ci/zorael/kameloso/master.svg?logo=appveyor&style=flat&maxAge=3600)](https://ci.appveyor.com/project/zorael/kameloso) [![Commits since last release](https://img.shields.io/github/commits-since/zorael/kameloso/v3.8.0.svg?logo=github&style=flat&maxAge=3600)](https://github.com/zorael/kameloso/compare/v3.8.0...master)

**kameloso** is an IRC bot with [Twitch support](#twitch).

## Current functionality includes:

* chat monitoring in your terminal
* channel polls, user quotes, `!seen`, counters, oneliners, timed announcements, ...
* reporting titles of pasted URLs, YouTube video information fetch
* `sed`-replacement of messages (`s/this/that/` substitution)
* saving notes to offline users that get played back when they come online
* logs
* bugs
* some common [Twitch bot features](#twitch-bot)
* [more random stuff and gimmicks](https://github.com/zorael/kameloso/wiki/Current-plugins)

All of the above are plugins and can be disabled at runtime or omitted from compilation entirely. It is modular and easy to extend. A skeletal Hello World plugin is [less than 30 lines of code](source/kameloso/plugins/hello.d).

Testing is primarily done on [**Libera.Chat**](https://libera.chat) and on [**Twitch**](https://www.twitch.tv), so support and coverage is best there.

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
           --bright Adjust colours for bright terminal backgrounds
       --monochrome Use monochrome output
             --save Write configuration to file
```

Prebuilt binaries for Windows and Linux can be found under [**Releases**](https://github.com/zorael/kameloso/releases).

To compile it yourself:

```console
$ dub run kameloso -- --server irc.libera.chat --homeChannels "#mychannel" --guestChannels "#d"

## alternatively, guaranteed latest
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
$ dub build
$ ./kameloso --server irc.libera.chat --homeChannels "#mychannel" --guestChannels "#d"
```

If there's anyone talking it should show up on your screen.

---

# Table of contents

* [Getting started](#getting-started)
  * [Prerequisites](#prerequisites)
     * [SSL libraries on Windows](#ssl-libraries-on-windows)
  * [Downloading source](#downloading-source)
  * [Compiling](#compiling)
    * [Build configurations](#build-configurations)
* [How to use](#how-to-use)
  * [Configuration](#configuration)
    * [Configuration file](#configuration-file)
    * [Command-line arguments](#command-line-arguments)
    * [Display settings](#display-settings)
    * [Other files](#other-files)
  * [Example use](#example-use)
    * [Online help and commands](#online-help-and-commands)
    * [***Except nothing happens***](#except-nothing-happens)
  * [**Twitch**](#twitch)
    * [**Copy/paste-friendly concrete setup from scratch**](#copy-paste-friendly-concrete-setup-from-scratch)
    * [Example configuration](#example-configuration)
    * [Long story](#long-story)
    * [Twitch bot](#twitch-bot)
      * [Song requests](#song-requests)
      * [Certain commands require higher permissions](#certain-commands-require-higher-permissions)
  * [Further help](#further-help)
* [Known issues](#known-issues)
  * [Windows](#windows)
* [Roadmap](#roadmap)
* [Built with](#built-with)
* [License](#license)
* [Acknowledgements](#acknowledgements)

---

# Getting started

Grab a prebuilt binary from under [**Releases**](https://github.com/zorael/kameloso/releases); alternatively, download the source and compile it yourself.

## Prerequisites

**kameloso** can be built using the reference compiler [**dmd**](https://dlang.org/download.html), with the LLVM-based [**ldc**](https://github.com/ldc-developers/ldc/releases) and with the GCC-based [**gdc**](https://gdcproject.org/downloads). **dmd** compiles very fast, while **ldc** and **gdc** are slower at compiling but produce faster code. Additionally, the latter two support more target architectures than **dmd** does (e.g. ARM). See [here](https://wiki.dlang.org/Compilers) for an overview of the available compiler vendors.

You need a compiler based on D version **2.085** or later (March 2019). For **ldc** this is version **1.15**, and for **gdc** this is release series **12**.

If your repositories (or other software sources) don't have compilers recent enough, you can use the official [`install.sh`](https://dlang.org/install.html) installation script to download current ones, or any version of choice. (**gdc** is not available via this script.)

The package manager [**dub**](https://code.dlang.org) is used to facilitate compilation and dependency management. On Windows it comes bundled in the compiler archive, while on Linux it may need to be installed separately. Refer to your repositories.

### SSL libraries on Windows

See the [known issues](#known-issues) section on Windows for information on libraries needed to connect to SSL servers and to allow plugins secure access to the Internet.

## Downloading source

```console
$ git clone https://github.com/zorael/kameloso.git
```

It can also be downloaded as a [`.zip` archive](https://github.com/zorael/kameloso/archive/master.zip).

## Compiling

```console
$ dub build
```

This will compile the bot in the default **debug** build type, which adds some extra code and debugging symbols. You can omit these and perform some optimisations by building it in **release** mode with `dub build -b release`. Mind that build times will increase accordingly. Refer to the output of `dub build --print-builds` for more build types.

### Build configurations

There are two major configurations in which the bot may be built.

* `application`: base configuration; everything needed for an IRC bot
* `twitch`: additionally includes Twitch chat support and the Twitch bot plugin

Both configurations come in `-lowmem` variants (e.g. `application-lowmem` and `twitch-lowmem`) that lower compilation memory required at the cost of increasing compilation time, which may help on memory-constrained systems.

List configurations with `dub build --print-configs`. You can specify which to compile with the `-c` switch. Not supplying one will make it build the default `application` configuration.

```console
$ dub build -c twitch
```

> If you want to slim down the program and customise your own build to only compile the plugins you want to use, see the larger `versions` lists in `dub.sdl`. Simply add a character to the line corresponding to the plugin(s) you want to omit, thus invalidating the version identifiers and effectively disabling the code they relate to. Mind that disabling any of the "**service**" plugins may/will break the bot in subtle ways.

# How to use

## Configuration

The bot ideally wants the account name of one or more administrators of the bot, and/or one or more home channels to operate in. Without either it's just a read-only log bot, which is a completely valid use-case. To define these you can either specify them on the command line, with flags listed by calling the program with `--help`, or generate a configuration file with `--save` and enter them there.

```console
$ kameloso --save
```

A new `kameloso.conf` will be created in a directory dependent on your platform.

### Configuration file

* **Linux** and other Posix: `$HOME/.config/kameloso` (overridden by `$XDG_CONFIG_HOME`)
* **Windows**: `%APPDATA%\kameloso`
* **macOS**: `$HOME/Library/Preferences/kameloso`

Open the file in a normal text editor.

> As a shortcut you can pass `--gedit` to attempt to open it in a **g**raphical **edit**or, or `--edit` to open it in your default terminal one, as defined in the `$EDITOR` environment variable.

### Command-line arguments

You can make changes to your configuration file in-place by specifying some at the command line and adding `--save`.

```shell
$ kameloso \
    --server irc.libera.chat \
    --nickname "kameloso" \
    --admins "you" \
    --homeChannels "#mychannel" \
    --guestChannels "#d,##networking" \
    --monochrome
    --save

[12:34:56] Configuration written to /home/user/.config/kameloso/kameloso.conf
```

Settings not touched will keep their values.

### Display settings

**kameloso**'s text colours are by default set to go well with dark terminal backgrounds. If you have a bright background, text may be difficult to read (e.g. white on white), depending on your terminal emulator. If so, pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses 7 colours out of [8-colour ANSI](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more colours are too dark or bright even with the right `brightTerminal` setting, please refer to your terminal appearance settings.

An alternative is to disable colours entirely with `--monochrome`.

### Other files

More server-specific resource files will be created the first time you connect to a server. These include `users.json`, in which you whitelist which accounts are allowed to access the bot's features on a per-channel basis. Where these are placed is platform-dependent.

* **Linux** and other Posix: `$HOME/.local/share/kameloso` (overridden by `$XDG_DATA_HOME`)
* **Windows**: `%LOCALAPPDATA%\kameloso`
* **macOS**: `$HOME/Library/Application Support/kameloso`

## Example use

See [the wiki](https://github.com/zorael/kameloso/wiki/Current-plugins) for more information on available plugins and their commands.

Additionally, see [this section about permissions](#except-nothing-happens) if nothing happens when you try to invoke commands.

```
      you joined #channel
 kameloso sets mode +o you

      you | I am a fish
      you | s/fish/snek/
 kameloso | you | I am a snek

    blarf | I am a snek too
      you | !addquote blarf I am a snek too
 kameloso | Quote added at index #4.
      you | !quote blarf
 kameloso | I am a snek too (blarf #4 2022-04-04)
      you | !quote blarf #3
 kameloso | A Møøse once bit my sister (blarf #3 2022-02-01)
      you | !quote blarf barnes and noble
 kameloso | i got kicked out of barnes and noble once for moving all the bibles into the fiction section (blarf #0 2019-08-21)

      you | !seen
 kameloso | Usage: !seen [nickname]
      you | !seen MrOffline
 kameloso | I last saw MrOffline 1 hour and 34 minutes ago.

 MrOnline | !note
 kameloso | Usage: !note [nickname] [note text]
 MrOnline | !note MrOffline About the thing you mentioned, yeah no
 kameloso | Note added.
 MrOnline left #channel
MrOffline joined #channel
 kameloso | MrOffline! MrOnline left note 4 hours and 28 minutes ago: About the thing you mentioned, yeah no

      you | !operator add bob
 kameloso | Added BOB as an operator in #channel.
      you | !whitelist add alice
 kameloso | Added Alice as a whitelisted user in #channel.
      you | !blacklist del steve
 kameloso | Removed steve as a blacklisted user in #channel.

      you | !automode
 kameloso | Usage: !automode [add|clear|list] [nickname/account] [mode]
      you | !automode add ray +o
 kameloso | Automode modified! ray on #channel: +o
      ray joined #channel
 kameloso sets mode +o ray

      you | !oneliner new
 kameloso | Usage: !oneliner new [trigger] [type] [optional cooldown]
      you | !oneliner new info random
 kameloso | Oneliner !info created! Use !oneliner add to add lines.
      you | !oneliner add info @$nickname: for more information just use Google
 kameloso | Oneliner line added.
      you | !oneliner add info @$nickname: for more information just use Bing
 kameloso | Oneliner line added.
      you | !oneliner new vods ordered
 kameloso | Oneliner !vods created! Use !oneliner add to add lines.
      you | !oneliner add vods See https://twitch.tv/zorael/videos for $streamer's on-demand videos (stored temporarily)
 kameloso | Oneliner line added.
      you | !oneliner new source ordered
 kameloso | Oneliner !source created! Use !oneliner add to add lines.
      you | !oneliner add source I am $bot. Peruse my source at https://github.com/zorael/kameloso
 kameloso | Oneliner line added.
      you | !info
 kameloso | @you: for more information just use Google
      you | !info
 kameloso | @you: for more information just use Bing
      you | !vods
 kameloso | See https://twitch.tv/zorael/videos for Channel's on-demand videos (stored temporarily)
      you | !commands
 kameloso | Available commands: !info, !vods, !source
      you | !oneliner del vods
 kameloso | Oneliner !vods removed.

      you | !timer new
 kameloso | Usage: !timer new [name] [type] [condition] [message threshold] [time threshold] [stagger message count] [stagger time]
      you | !timer new mytimer ordered both 100 600 0 0
 kameloso | New timer added! Use !timer add to add lines.
      you | !timer add mytimer This is an announcement on a timer
 kameloso | Line added to timer mytimer.
      you | !timer add mytimer It is sent after 100 messages have been seen and 600 seconds have passed
 kameloso | Line added to timer mytimer.
(...time passes, messages get sent...)
 kameloso | This is an announcement on a timer
(...time passes, messages get sent...)
 kameloso | It is sent after 100 messages have been seen and 600 seconds have passed
      you | !timer suspend mytimer
 kameloso | Timer suspended. Use !timer resume mytimer to resume it.
      you | !timer resume mytimer
 kameloso | Timer resumed!

      you | !poll
 kameloso | Usage: !poll [seconds] [choice1] [choice2] ...
      you | !poll 2m snik snek
 kameloso | Voting commenced! Please place your vote for one of: snek, snik (2 minutes)
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

(context: playing a video game)
      you | !counter
 kameloso | Usage: !counter [add|del|format|list] [counter word]
      you | !counter add deaths
 kameloso | Counter deaths added! Access it with !deaths.
      you | !deaths+
 kameloso | deaths +1! Current count: 1
      you | !deaths+3
 kameloso | deaths +3! Current count: 4
      you | !deaths
 kameloso | Current deaths count: 4
      you | !deaths=0
 kameloso | deaths count assigned to 0!

      you | !stopwatch start
 kameloso | Stopwatch started!
      you | !stopwatch
 kameloso | Elapsed time: 18 minutes and 42 seconds
      you | !stopwatch stop
 kameloso | Stopwatch stopped after 1 hour, 48 minutes and 10 seconds.

      you | !time
 kameloso | The time is currently 12:04 locally.
      you | !time Europe/London
 kameloso | The time is currently 11:04 in Europe/Stockholm.
      you | !time Tokyo
 kameloso | The time is currently 20:05 in Tokyo.
      you | !setzone Helsinki
 kameloso | Timezone changed to Europe/Helsinki.
      you | !time
 kameloso | The time is currently 12:04 in Europe/Helsinki.
```

### Online help and commands

Use the `!help` command for a summary of available bot commands, and `!help [plugin] [command]` for a brief description of a specific one. The shorthand `!help !command` also works.

The command **prefix** (here "`!`") is configurable; refer to your configuration file. Common alternatives are `.` (dot), `~` (tilde) and `?`, making it `.note`, `~quote` and `?counter` respectively.

```ini
[Core]
prefix                      "!"
```

It can technically be any string and not just one character. It may include spaces if enclosed within quotes, like `"please "` (making it `please note`, `please quote`, ...). Additionally, prefixing commands with the bot's nickname also always works, as in `kameloso: seen MrOffline`. This is to be able to disambiguate between several bots in the same channel. Moreover, many administrative commands only work when called this way, notably everything that only outputs information to the local terminal.

### ***Except nothing happens***

Before allowing *anyone* to trigger any restricted functionality, the bot will try to identify the accessing user by querying the server for what **services account** that user is logged onto, if not already known. For full and global administrative privileges you will need to be logged into services with an account listed in the `admins` field in the configuration file, while other users may be defined with other per-channel permissions in your [`users.json`](#other-files) file. If a user is not logged onto services it is considered as not being uniquely identifiable and cannot be resolved to an account.

In the case of **hostmasks mode**, the above still applies but "accounts" are derived from user hostmasks. See the **Admin** plugin `!hostmask` command (and the [`hostmasks.json`](#other-files) file) for how to map hostmasks to would-be accounts. Hostmasks are a weaker solution to user identification, but not all servers offer services. More information can be found in [the wiki entry on hostmasks](https://github.com/zorael/kameloso/wiki/On-servers-without-services-(e.g.-no-NickServ)).

## **Twitch**

> **If you're interested in trying the bot but don't want to run it yourself, [contact me](mailto:zorael@gmail.com?subject=kameloso) and I'll host an instance on a headless server.**

### **Copy paste-friendly concrete setup from scratch**

Pre-compiled binaries for Windows and Linux can be found under [Releases](https://github.com/zorael/kameloso/releases).

If you're on Windows, you must first [install the **OpenSSL** library](#windows). Run this command to download and launch the installer for it, then opt to install to Windows system directories when asked:

```shell
kameloso --get-openssl
```

The rest is common for all platforms.

```shell
kameloso --setup-twitch
```

The `--setup-twitch` command creates a configuration file with the server address and port already set to connect to Twitch, then opens it up in a text editor.

**A line with a leading `#` is disabled, so remove any `#`s from the heads of entries you want to enable.**

* Add your channel to `homeChannels`. Channel names are account names (which are always lowercase) with a `#` in front, so the Twitch user `Streamer123` would have the channel `#streamer123`.
* Optionally add an account name to `admins` to give them global low-level control of the bot. Owners of channels (broadcasters) automatically have high privileges in the scope of their own channels, so it's not strictly needed.
* You can ignore `nickname`, `user`, `realName`, `account` and `password`, as they're not applicable on Twitch. Do not enter your Twitch password anywhere.
* Peruse the file for other settings if you want; you can always get back to it by passing `--gedit` (short for **g**raphical **edit**or).

The program can then be run normally.

```shell
kameloso
```

It will connect to Twitch and start the guide to requesting a new *authorisation token* in your terminal, upon detecting it's missing one. See the ["long story"](#long-story) section below for details.

**Note that it will request a token for the user you are currently logged in as in your browser**. If you want one for a different "bot user" instead, open up a private/incognito window, log into Twitch normally **with the bot account** there, copy [**this link**](https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=tjyryd2ojnqr8a51ml19kn1yi2n0v1&redirect_uri=http://localhost&scope=channel:moderate+chat:edit+chat:read+whispers:edit+whispers:read&force_verify=true), then paste it into that browser window instead. (Then follow the terminal instructions again.)

After obtaining a token it will save it to your configuration file and reconnect to the server. Provided there were no errors, the bot should now enter your channel. Say something in your channel's chat in your browser, and it should show in your terminal. If there were errors or snags, please [report them](https://github.com/zorael/kameloso/issues/new).

> If you don't like the terminal colouring, `--monochrome` disables it.

### Example configuration

```ini
[IRCClient]
nickname                    doesntmatter
user                        ignored
realName                    likewise

[IRCBot]
#account
#password                   <do not enter your Twitch account password!>
pass                        <twitch.keygen authorisation token for bot account>
admins                      mainaccount
homeChannels                #mainaccount,#botaccount
#guestChannels

[IRCServer]
address                     irc.chat.twitch.tv
port                        6697

[Twitch]
enabled                     true
ecount                      true
watchtime                   true
songrequestMode             youtube
songrequestPermsNeeded      whitelist
promoteBroadcasters         true
promoteModerators           true
promoteVIPs                 true
```

The secure port is **6697** (or **443**). For non-encrypted traffic, use the default port **6667**.

### **Long story**

To connect to Twitch servers, you must first compile the `twitch` build configuration to include Twitch support. **All pre-compiled binaries available from under [Releases](https://github.com/zorael/kameloso/releases) are already built this way.**

You will also require an [*authorisation token*](https://en.wikipedia.org/wiki/OAuth). Assuming you have a configuration file set up to connect to Twitch, it will automatically start the guide to requesting one upon connecting, if none is present. Run the bot with `--set twitch.keygen` to force it if it doesn't, or if your token expired. (They last about 60 days.)

It will open a browser window in which you are asked to log onto Twitch *on Twitch's own servers*. Verify this by checking the page address; it should end with `.twitch.tv`, with the little lock symbol showing the connection is secure.

> Note: At no point is the bot privy to your Twitch login credentials! The logging-in is wholly done on Twitch's own servers, and no information is sent to any third parties. Note that the generated token should still be kept secret. The code that deals with all this is open for audit; [`requestTwitchKey` in `plugins/twitch/keygen.d`](source/kameloso/plugins/twitch/keygen.d).

After entering your login and password and clicking **Authorize**, you will be redirected to an empty "`this site can't be reached`" or "`unable to connect`" page. **Copy the URL address of it** and **paste** it into the terminal, when prompted to. It will parse the address, extract your authorisation token, and save it to your configuration file.

If you prefer to generate the token manually, [**here is the URL you need to follow**](https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=tjyryd2ojnqr8a51ml19kn1yi2n0v1&redirect_uri=http://localhost&scope=channel:moderate+chat:edit+chat:read+whispers:edit+whispers:read&force_verify=true). The only thing the generation process does is open it for you, as well as automating saving the end token to your configuration file (as `pass` under `[IRCBot]`).

> Mind that the authorisation token should be kept secret. It's not possible to derive your Twitch account password from it, but anyone with access to the token can chat as if they were you.

### Twitch bot

**Please make the bot a moderator to prevent its messages from being as aggressively rate-limited.**

Assuming a prefix of `!`, commands to test are:

* `!uptime`
* `!followage`
* `!vanish`
* `!repeat`
* `!ecount`
* `!watchtime`
* `!nuke`
* `!songrequest`
* `!settitle`
* `!setgame`
* `!commercial`
* `!startpoll`/`!endpoll` (*highly* experimental, need help from affiliate)

...alongside `!oneliner`, `!counter`, `!timer`, `!poll` (chat poll), `!time`, `!stopwatch`, and other non-Twitch-specific commands. Try `!help` or [the wiki](https://github.com/zorael/kameloso/wiki/Current-plugins).

> Note: `.` (dot) and `/` (slash) prefixes will not work on Twitch.

#### Song requests

To get song requests to work, you need to register an *application* to interface with [Google (YouTube)](https://console.cloud.google.com/projectcreate) and/or [Spotify](https://developer.spotify.com/dashboard) servers individually. To initiate the guides for this, pass `--set twitch.googleKeygen` for YouTube and `--set twitch.spotifyKeygen` for Spotify, then simply follow the on-screen instructions. (They behave much like `--set twitch.keygen`.)

#### Certain commands require higher permissions

Some functionality, such as setting the channel title or currently played game, require elevated credentials with the permissions of the channel owner (broadcaster). As such, if you want to use such commands, you will need to generate an OAuth authorisation token for **your main account** separately, much as you generated one to be able to connect with the bot account. This will request a token from Twitch with more permissions, and the authorisation browser page should reflect this.

```shell
$ kameloso --set twitch.superKeygen
```

> Mind that you need to be logged into Twitch (in your browser) with your **main account** while doing this, or the token obtained will be with permissions for the wrong channel.

All keygens can be triggered at the same time.

```shell
$ kameloso \
    --set twitch.keygen \
    --set twitch.superKeygen \
    --set twitch.googleKeygen \
    --set twitch.spotifyKeygen
```

## Further help

For more information and help, first refer to [the wiki](https://github.com/zorael/kameloso/wiki).

If you still can't find what you're looking for, or if you have suggestions on how to improve the bot, you can...

* ...start a thread under [Discussions](https://github.com/zorael/kameloso/discussions)
* ...file a [GitHub issue](https://github.com/zorael/kameloso/issues/new)

# Known issues

## Windows

**kameloso** uses [**OpenSSL**](https://www.openssl.org) to establish secure connections. It is the de facto standard library for such in the Posix sphere (Linux, macOS, ...), but not so on Windows. If you run into errors about missing SSL libraries when attempting to connect on Windows, pass the `--get-openssl` flag to download and launch the installer for [**OpenSSL for Windows v1.1.\***](https://slproweb.com/products/Win32OpenSSL.html). Make sure to opt to install to Windows system directories when asked.

## Google/YouTube song request playlist integration

If you're doing everything right and you still get permissions errors when attempting to add a YouTube video clip to a playlist, make sure that you pick a **YouTube account** during the keygen process when you're asked to select one of your accounts, as opposed to an overarching **Google account**. It should say **YouTube** underneath the option.

# Roadmap

* pipedream zero: **no compiler segfaults** ([#18026](https://issues.dlang.org/show_bug.cgi?id=18026), [#20562](https://issues.dlang.org/show_bug.cgi?id=20562))
* please send help: Windows Secure Channel SSL
* **more pairs of eyes** (if you don't test it, it's broken)

# Built with

* [**D**](https://dlang.org)
* [`dub`](https://code.dlang.org)
* [`dialect`](https://github.com/zorael/dialect) ([dub](https://code.dlang.org/packages/dialect))
* [`lu`](https://github.com/zorael/lu) ([dub](https://code.dlang.org/packages/lu))
* [`requests`](https://github.com/ikod/dlang-requests) ([dub](https://code.dlang.org/packages/requests))
* [`arsd`](https://github.com/adamdruppe/arsd) ([dub](https://code.dlang.org/packages/arsd-official))

# License

This project is licensed under the **Boost Software License 1.0** - see the [LICENSE_1_0.txt](LICENSE_1_0.txt) file for details.

# Acknowledgements

* [Kamelåså](https://youtu.be/ykj3Kpm3O0g)
* [ikod](https://github.com/ikod) for [`dlang-requests`](https://github.com/ikod/dlang-requests)
* [Adam D. Ruppe](https://github.com/adamdruppe) for [`arsd`](https://github.com/adamdruppe/arsd)
* [`#d` on libera.chat](irc://irc.libera.chat:6697/#d)
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on libera.chat](irc://irc.libera.chat:6667/#ircdocs)

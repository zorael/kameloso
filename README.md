# kameloso [![Linux/macOS](https://img.shields.io/circleci/project/github/zorael/kameloso/master.svg?maxAge=3600&logo=circleci)](https://circleci.com/gh/zorael/kameloso) [![Linux/macOS](https://img.shields.io/travis/zorael/kameloso/master.svg?maxAge=3600&logo=travis)](https://travis-ci.com/zorael/kameloso) [![Windows](https://img.shields.io/appveyor/ci/zorael/kameloso/master.svg?maxAge=3600&logo=appveyor)](https://ci.appveyor.com/project/zorael/kameloso) [![Commits since last release](https://img.shields.io/github/commits-since/zorael/kameloso/v1.8.2.svg?maxAge=3600&logo=github)](https://github.com/zorael/kameloso/compare/v1.8.2...master)

**kameloso** idles in your channels and listens to commands and events, like bots generally do.

## Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* automatic mode sets (eg. auto `+o` on join for op)
* logs
* fetching and echoing titles of pasted URLs
* **sed**-replacement of the last message sent (`s/this/that/` substitution)
* saving notes to offline users that get played back when they come online
* channel polls
* works on **Twitch**, including optional [streamer plugin](source/kameloso/plugins/twitchbot/package.d)
* **SSL** support, including certificate and private key authentication
* more [random stuff and gimmicks](https://github.com/zorael/kameloso/wiki/Current-plugins)

All of the above are plugins and can be runtime-disabled or compiled out. It is modular and easily extensible. A skeletal Hello World plugin is [20 lines of code](source/kameloso/plugins/hello.d).

Testing is primarily done on [**freenode**](https://freenode.net) and on [**Twitch**](https://dev.twitch.tv/docs/irc/guide) servers, so support and coverage is best there.

**Please report bugs. Unreported bugs can only be fixed by accident.**

# TL;DR

```
-n       --nickname Nickname
-s         --server Server address [irc.freenode.net]
-P           --port Server port [6667]
-A        --account Services account name
-p       --password Services account password
           --admins Administrators' services accounts, comma-separated
-H   --homeChannels Home channels to operate in, comma-separated
-C  --guestChannels Non-home channels to idle in, comma-separated
-w    --writeconfig Write configuration to file

A dash (-) clears, so -C- translates to no channels, -A- to no account name, etc.
```

```sh
$ dub run kameloso -- --server irc.freenode.net --guestChannels "#d,#freenode"

# alternatively
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
$ dub build
$ ./kameloso --server irc.freenode.net --guestChannels "#d,#freenode"
```

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
  * [Twitch](#twitch)
    * [Example configuration](#example-configuration)
    * [Streamer assistant bot](#streamer-assistant-bot)
  * [Further help](#further-help)
* [Known issues](#known-issues)
  * [Windows](#windows)
  * [Posix](#posix)
* [Roadmap](#roadmap)
* [Built with](#built-with)
* [License](#license)
* [Acknowledgements](#acknowledgements)

---

# Getting started

## Prerequisites

There are three [D](https://dlang.org) compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview. You need one based on D version **2.084** or later (January 2019).

**kameloso** can be built using the reference compiler [**dmd**](https://dlang.org/download.html), which compiles very fast; and the LLVM-based [**ldc**](https://github.com/ldc-developers/ldc/releases), which is slower but produces faster code. The stable release of the GCC-based [**gdc**](https://gdcproject.org/downloads) is currently based on version **2.076** and is thus too old to be used.

The package manager [**dub**](https://code.dlang.org) is used to facilitate compilation and dependency management. On Windows it comes bundled in the compiler archive, while on Linux it will need to be installed separately. Refer to your repositories.

## Downloading

```sh
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
```

## Compiling

```sh
$ dub build
```

This will compile the bot in the default `debug` mode, which adds some extra code and debugging symbols.

You can automatically skip these and add some optimisations by building it in `release` mode with `dub build -b release`. Mind that build times will increase. Refer to the output of `dub build --help` for more build types.

> The above *might* not work, albeit rarely, as the compiler may crash on some build configurations under anything other than `debug` mode. (bug [#18026](https://issues.dlang.org/show_bug.cgi?id=18026))

On Windows with **dmd 2.089 and above** builds may fail, either silently with no output, or with an `OutOfMemoryError` being thrown. See [issue #83](https://github.com/zorael/kameloso/issues/83). The workarounds are to either use the **ldc** compiler with `--compiler=ldc2`, or to build with the `--build-mode=singleFile` flag, both appended to the `dub build` command.

`singleFile` mode compiles one file at a time and as such drastically increases build times by at least a factor of 4x. While **ldc** is slower to compile than the default **dmd**, it's not *that* slow. In addition it also produces faster binaries, so if you hit this bug **ldc** might be the better alternative, over `singleFile`.

### Build configurations

There are several configurations in which the bot may be built.

* `application`, default configuration; includes terminal colours and plugins that access the web (both can still be disabled in runtime)
* `vanilla`, barebones build with most plugins but without colours or any specific extras
* `twitch`, essentially `application` plus Twitch support and the Twitch streamer plugin
* `dev`, all-inclusive development build equalling everything available, including things like more detailed error messages

> All configurations come in a `-lowmem` variant (e.g. `application-lowmem`, `twitch-lowmem`, ...} that lowers compilation memory by raising compilation time, but so far they *only work with **ldc***. (bug [#20699](https://issues.dlang.org/show_bug.cgi?id=20699))

List them with `dub build --print-configs`. You can specify which to compile with the `-c` switch. Not supplying one will make it build the default `application` configuration.

```sh
$ dub build -c twitch
```

> If you want to customise your own build to only compile the plugins you want to use, see the larger `versions` list in `dub.sdl`. Simply delete the lines that relate to the plugins you want to omit.

# How to use

## Configuration

The bot needs the account name of one or more administrators of the bot, and/or one or more home channels to operate in. Without either it's just a read-only log bot. To define these you can either specify them on the command-line, or generate a configuration file and enter them there.

```sh
$ ./kameloso --writeconfig
```

A new `kameloso.conf` will be created in a directory dependent on your platform.

* **Linux/FreeBSD**: `~/.config/kameloso` (alternatively where `$XDG_CONFIG_HOME` points)
* **macOS**: `$HOME/Library/Application Support/kameloso`
* **Windows**: `%APPDATA%\kameloso`
* **Other unexpected platforms**: fallback to current working directory

Open the file in a normal text editor. If you have your system file associations set up to open `*.conf` files in an editor, you can open it by passing `--edit`.

### Command-line arguments

You can override some configured settings with arguments on the command line, listed by calling the program with `--help`. If you specify some and also add `--writeconfig`, it will apply and save these changes to the configuration file, without having to manually edit it.

```sh
$ ./kameloso \
    --server irc.freenode.net \
    --nickname "kameloso" \
    --admins "you,friend,thatguy" \
    --homeChannels "#channel,#elsewhere" \
    --guestChannels "#d,##networking" \
    --writeconfig

Configuration file written to /home/user/.config/kameloso/kameloso.conf
```

Later invocations of `--writeconfig` will regenerate the file. It will never overwrite custom settings, only complement them with new ones. Mind however that it will delete any lines not corresponding to a currently *available* setting, so settings that relate to plugins *that are currently not built in* are silently removed.

### Display settings

If you have bright terminal background, the colours may be hard to see and the text difficult to read. If so, pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses the full range of [8-colour ANSI](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more colours are too dark or bright even with the right `brightTerminal` setting, please refer to your terminal appearance settings. An alternative is to disable colours entirely with `--monochrome`.

### Other files

More server-specific resource files will be created the first time you connect to a server. These include `users.json`, in which you whitelist which accounts get to access the bot's features. Where these are stored also depends on platform; in the case of **macOS** and **Windows** they will be put in server-split subdirectories of the same directory as the configuration file, listed above. On **Linux**, under `~/.local/share/kameloso` (or wherever `$XDG_DATA_HOME` points). As before it falls back to the working directory on other unexpected platforms.

## Example use

Mind that you need to authorise yourself with services with an account listed as an administrator in the configuration file to make it listen to you. Before allowing *anyone* to trigger any restricted functionality it will look them up and compare their accounts with those defined in your `users.json`. You should add your own to the `admins` field in the configuration file for full administrative privileges.

> In the case of hostmasks mode, the previous paragraph still applies but to hostmasks instead of to services accounts. See the `hostmasks.json` file for how to map hostmasks to would-be accounts.

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
```

### Online help and commands

Use the `!help` command for a summary of available bot commands, and `!help [plugin] [command]` for a brief description of a specific one.

The **prefix** character (here `!`) is configurable; refer to your generated configuration file. Common alternatives are `.` and `~`, making it `.note` and `~quote` respectively.

```ini
[Core]
prefix              "!"
```

It can technically be any string and not just one character. It may include spaces, like `"please "` (making it `please note`, `please quote`, ...). Prefixing commands with the bot's nickname also works, as in `kameloso: seen MrOffline`. Some administrative commands only work when called this way.

## Twitch

To connect to Twitch servers you must first build a configuration that includes support for it, which is currently either `twitch` or `dev`.

You must also supply an [OAuth token](https://en.wikipedia.org/wiki/OAuth) **pass** (not password). These authorisation tokens are unique to your user, *paired* with an application. As such, you need a new one for each and every program you want to access Twitch with, this one being no exception.

Run the bot with `--set twitchbot.keyGenerationMode` to start the captive process of generating one. It will open a browser window, in which you are asked to log onto Twitch *on Twitch's own servers*. Verify this by checking the page address; it should end with `twitch.tv`, with the little lock symbol showing the connection is secure.

> Note: At no point is the bot privy to your login credentials! The logging-in is wholly done on Twitch's own servers, and no information is sent to any third parties. The code that deals with this is open for audit; [`generateKey` in `twitchbot/api.d`](source/kameloso/plugins/twitchbot/api.d).

After entering your login and password and clicking **Authorize**, you will be redirected to an empty "this site can't be reached" page. Copy the URL address of it and paste it into the terminal, when asked. It will parse the address, extract your authorisation token, and offer to save it to your `kameloso.conf` configuration file.

If you prefer to generate the token manually, here is the URL you need to follow. The only thing the generation process does is open it for you, and help with saving the end key to disk.

```
https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=tjyryd2ojnqr8a51ml19kn1yi2n0v1&redirect_uri=http://localhost&scope=bits:read+channel:edit:commercial+channel:read:subscriptions+user:edit+user:edit:broadcast+channel_editor+user_blocks_edit+user_blocks_read+user_follows_edit+channel:moderate+chat:edit+chat:read+whispers:edit+whispers:read
```

### Example configuration

```ini
[IRCClient]
nickname            yourtwitchaccount
user                ignored
realName            likewise

[IRCBot]
#account
#password
pass                oauth:personalauthorisationtoken
admins              otheraccount
homeChannels        #yourtwitchaccount,#otheraccount
guestChannels       #streamer1,#streamer2,#streamer3

[IRCServer]
address             irc.chat.twitch.tv
port                6667
```

See [the wiki page on Twitch](https://github.com/zorael/kameloso/wiki/Twitch) for more information.

### Streamer assistant bot

The streamer bot plugin is opt-in during compilation; build the `twitch` configuration to compile it. Even if built it can be disabled in the configuration file under the `[TwitchBot]` section. If the section doesn't exist, regenerate the file after having compiled a build configuration that includes the bot plugin. As previously alluded to, configuration file sections will not show up when generating the file if the corresponding plugin is not compiled in.

```sh
$ dub build -c twitch
$ ./kameloso --set twitchbot.enabled=false --writeconfig
```

Assuming a prefix of "`!`", commands to test are: `!uptime`, `!start`, `!stop`, `!enable`, `!disable`, `!phrase`, `!timer`, `!permit`, `!followage` (alongside `!operator`, `!whitelist`, `!blacklist`, `!oneliner`, `!poll`, and other non-Twitch-specific commands.)

> Note: dot "`.`" and slash "`/`" prefixes will not work on Twitch, as they conflict with Twitch's own commands.

To disable heavier commands that access Twitch's API (currently only the `!followage` command), set `enableAPIFeatures` under `[TwitchBot]` in the configuration file to `false`.

Do not set `keyGenerationMode` persistently to `true` in the configuration file, or you will be led to the generation guide on every startup.

**Please make the bot a moderator to prevent its messages from being as aggressively rate-limited.**

## Further help

For more information and help see [the wiki](https://github.com/zorael/kameloso/wiki), or [file an issue](https://github.com/zorael/kameloso/issues/new).

There is also a channel `#kameloso` on freenode, but replies may be delayed.

# Known issues

## Windows

If SSL flat doesn't work at all, you may simply be missing the necessary libraries. Download and install **OpenSSL** [here](https://slproweb.com/products/Win32OpenSSL.html), and install to system directories when asked.

Even with SSL working, you may see errors of *"Peer certificates cannot be authenticated with given CA certificates"*. If this happens, download this [`cacert.pem`](https://curl.haxx.se/ca/cacert.pem) file, place it somewhere reasonable, and edit your configuration file to point to it; `caBundleFile` under `[Connection]`.

In Cygwin/mintty terminals, there may be garbage "`[39m`" characters randomly at the beginning of lines, and lines may arbitrarily break at a certain length. Unsure how to solve this. The current workaround is to just use `cmd.exe` and/or the Powershell console instead.

## Posix

If the pipeline FIFO is removed while the program is running, it will hang upon exiting, requiring manual interruption with Ctrl+C. This is a tricky problem to solve as it requires figuring out how to do non-blocking reads. Help wanted.

# Roadmap

* pipedream zero: **no compiler segfaults** ([#18026](https://issues.dlang.org/show_bug.cgi?id=18026))
* pipedream: DCC
* non-blocking FIFO
* more pairs of eyes

# Built with

* [**D**](https://dlang.org)
* [`dub`](https://code.dlang.org)
* [`dialect`](https://github.com/zorael/dialect) ([dub](https://code.dlang.org/packages/dialect))
* [`lu`](https://github.com/zorael/lu) ([dub](https://code.dlang.org/packages/lu))
* [`arsd`](https://github.com/adamdruppe/arsd) ([dub](https://code.dlang.org/packages/arsd-official))

# License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

# Acknowledgements

* [Kameloso](https://youtu.be/ykj3Kpm3O0g)
* [`README.md` template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [ikod](https://github.com/ikod) for [`dlang-requests`](https://github.com/ikod/dlang-requests)
* [Adam D. Ruppe](https://github.com/adamdruppe) for [`arsd`](https://github.com/adamdruppe/arsd)
* [`#d` on freenode](irc://irc.freenode.org:6667/#d)
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on freenode](irc://irc.freenode.org:6667/#ircdocs)

# kameloso [![CircleCI Linux/OSX](https://img.shields.io/circleci/project/github/zorael/kameloso/master.svg?maxAge=3600&logo=circleci)](https://circleci.com/gh/zorael/kameloso) [![Travis Linux/OSX and documentation](https://img.shields.io/travis/zorael/kameloso/master.svg?maxAge=3600&logo=travis)](https://travis-ci.org/zorael/kameloso) [![Windows](https://img.shields.io/appveyor/ci/zorael/kameloso/master.svg?maxAge=3600&logo=appveyor)](https://ci.appveyor.com/project/zorael/kameloso) [![Issue 46](https://img.shields.io/github/issues/detail/s/zorael/kameloso/46.svg?maxAge=3600)](https://github.com/zorael/kameloso/issues/46) [![GitHub commits since last release](https://img.shields.io/github/commits-since/zorael/kameloso/v1.0.0-rc.4.svg?maxAge=3600&logo=github)](https://github.com/zorael/kameloso/compare/v1.0.0-rc.4...master)

**kameloso** sits and listens in the channels you specify and reacts to events, like bots generally do.

A variety of features comes bundled in the form of compile-time plugins, including some examples and proofs of concepts. It's made to be easy to write your own (API documentation is [available online](https://zorael.github.io/kameloso)). Any and all ideas for inclusion welcome.

IRC is standardised but servers still come in [many flavours](https://upload.wikimedia.org/wikipedia/commons/thumb/d/d5/IRCd_software_implementations3.svg/1533px-IRCd_software_implementations3.svg.png), some of which [outright conflict](http://defs.ircdocs.horse/defs/numerics.html) with others. If something doesn't immediately work, usually it's because we simply haven't encountered that type of event before, and so no rules for how to parse it have been written yet. Once discovered it's not a difficult thing to do.

Please report bugs. Unreported bugs can only be fixed by accident.

## Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* automatic mode sets (eg. auto `+o` on join for op)
* looking up titles of pasted web URLs
* logs
* `sed`-replacement of the last message sent (`s/this/that/` substitution)
* saving `notes` to offline users that get played back when they come online
* [`seen`](source/kameloso/plugins/seen.d) plugin; reporting when a user was last seen, written as a rough example plugin
* user `quotes`
* Twitch chat support, including basic [streamer bot](source/kameloso/plugins/twitchbot.d) (default disabled); see [notes on connecting](#twitch) below
* piping text from the terminal to the server (Linux/OSX and other Posix platforms only)
* mIRC colour coding and text effects (bold, underlined, ...), mapped to ANSI terminal formatting ([extra step](#windows) needed for Windows)
* [SASL](https://en.wikipedia.org/wiki/Simple_Authentication_and_Security_Layer) authentication (`plain`)
* configuration stored on file; [create one](#configuration) and edit it to get an idea of the settings available

If nothing else it makes for a good lurkbot.

## Current limitations:

* missing good how-to-use guide. Use the source, Luke! Also [the wiki](https://github.com/zorael/kameloso/wiki).
* the dmd and ldc compilers may segfault if building in anything other than `debug` mode (bug [#18026](https://issues.dlang.org/show_bug.cgi?id=18026)).
* Windows may need a registry fix to display terminal colours properly; see the [known issues](#known-issues) section.
* the stable release of the **gdc** compiler doesn't yet support `static foreach` and thus cannot be used to build this bot. The development release based on D version **2.081** doesn't work yet either, segfaulting upon compiling (bug [#307](https://bugzilla.gdcproject.org/show_bug.cgi?id=307)).
* IRC servers that have not been tested against may exhibit weird behaviour if parsing goes awry. Need concrete examples to fix; please report errors and abnormalities.

Use on networks without [*services*](https://en.wikipedia.org/wiki/IRC_services) (`NickServ`/`Q`/`AuthServ`/...) may be difficult, since the bot identifies people by their account names. You will probably want to register yourself with such, where available.

Testing is primarily done on [**freenode**](https://freenode.net) and on [**Twitch**](https://help.twitch.tv/customer/portal/articles/1302780-twitch-irc), so support and coverage is best there.

# TL;DR: abridged

```
-n       --nickname Nickname
-s         --server Server address [irc.freenode.net]
-P           --port Server port [6667]
-A        --account Services account name
-p       --password Services account password
           --admins Administrators' services accounts, comma-separated
-H          --homes Home channels to operate in, comma-separated
-C       --channels Non-home channels to idle in, comma-separated
-w    --writeconfig Write configuration to file

A dash (-) clears, so -C- translates to no channels, -A- to no account name, etc.
```

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
    * [Twitch bot](#twitch-bot)
  * [Use as a library](#use-as-a-library)
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

You need a D compiler and the [**dub**](https://code.dlang.org/download) package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview. You need one based on D version **2.076** or later (released September 2017). You will also need some 4 Gb of RAM to build all features (Linux, excluding tests).

**kameloso** can be built using the reference compiler [**dmd**](https://dlang.org/download.html) and the LLVM-based [**ldc**](https://github.com/ldc-developers/ldc/releases). The stable release of the GCC-based [**gdc**](https://gdcproject.org/downloads) is currently too old to be used.

## Downloading

```bash
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
```

Note: do not use `dub fetch` until we have released **v1.0.0**. It will download an ancient version.

## Compiling

```bash
$ dub build
```

This will compile the bot in the default `debug` mode, which adds some extra code and debugging symbols.

> You can automatically skip these and add some optimisations by building it in `release` mode with `dub build -b release`. Mind that build times will increase. Refer to the output of `dub build --help` for more build types.

The above might currently not work, as the compiler may crash on some build configurations under anything other than `debug` mode. (bug [#18026](https://issues.dlang.org/show_bug.cgi?id=18026))

Unit tests are built into the language, but you need to compile the project in `unittest` mode to include them. Tests are run at the *start* of the program, not during compilation. Test builds will only run the unit tests and immediately exit.

```bash
$ dub test
```

### Build configurations

There are several configurations in which the bot may be built.

* `vanilla`, builds without any specific extras
* `colours`, compiles in terminal colours
* `web`, compiles in plugins with web lookup (`webtitles`, `reddit` and `bashquotes`)
* `full`, includes both of the above
* `twitch`, everything so far, plus the example Twitch bot
* `posix`, default on Posix-like systems (Linux, OSX, ...), equals `full`
* `windows`, default on Windows, also equals `full`
* `cygwin`, equals `full` but with extra code needed for running under the default Cygwin terminal (**mintty**)
* `twitch+cygwin`, `cygwin` but with the Twitch bot
* `polyglot`, equals everything available, including things like the Admin plugin being able to see Twitch users (more of a development build)

List them with `dub build --print-configs`. You can specify which to compile with the `-c` switch. Not supplying one will make it build the default for your operating system.

```bash
$ dub build -c cygwin
```

# How to use

## Configuration

The bot needs the services account name of one or more administrators of the bot, and/or one or more home channels to operate in. To define these you can either specify them on the command-line, or generate a configuration file and enter them there.

```bash
$ ./kameloso --writeconfig
```

A new `kameloso.conf` will be created in a directory dependent on your platform.

* Linux: `~/.config/kameloso` (alternatively where `$XDG_CONFIG_HOME` points)
* OSX: `$HOME/Library/Application Support/kameloso`
* Windows: `%LOCALAPPDATA%\kameloso`
* Other unexpected platforms: fallback to current working directory

Open the file in a text editor and fill in the fields.

### Command-line arguments

You can override some settings with arguments on the command line, listed by calling the program with `--help`. If you specify some and also add `--writeconfig` it will save these changes to the file so you don't have to repeat them, without having to manually edit the configuration file.

```bash
$ ./kameloso \
    --server irc.freenode.net \
    --nickname "kameloso" \
    --admins "you,friend,thatguy" \
    --homes "#channel,#elsewhere" \
    --channels "#d,##networking" \
    --writeconfig

Configuration file written to /home/user/.config/kameloso/kameloso.conf
```

Later invocations of `--writeconfig` will only regenerate the file. It will never overwrite custom settings, only complement them with new ones. Mind however that it will delete any lines not corresponding to a valid setting, so comments are removed.

### Display settings

If you have compiled in colours and you have bright terminal background, the colours may be hard to see and the text difficult to read. If so, make sure to pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses the full range of [8-colour ANSI](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more colours are too dark or bright even with the right `brightTerminal` setting, please see to your terminal appearance settings. This is not uncommon, especially with backgrounds that are not fully black or white. (read: Monokai, Breeze, Solaris, ...)

If you are on Windows and you're seeing weird `\033[92m`-like characters instead of colours, see the [known issues](#known-issues) section for a fix.

### Other files

More server-specific resource files will be created the first time you connect to a server. These include `users.json`, in which you whitelist which accounts get to access the bot's features. Where these are stored also depends on platform; in the case of **OSX** and **Windows** they will be put in subdirectories of the same directory as the configuration file, listed above. On **Linux**, under `~/.local/share/kameloso` (or wherever `$XDG_DATA_HOME` points). As before it falls back to the working directory on other unknown platforms.

## Example use

Once the bot has joined a home channel, it's ready. Mind that you need to authorise yourself with services with an account listed as an administrator in the configuration file to make it listen to you. Before allowing *anyone* to trigger any functionality it will look them up and compare their accounts with the white- and blacklists. Refer to the `admins` field in the configuration file, as well as your generated `users.json`.

```
     you joined #channel
kameloso sets mode +o you
     you | I am a fish
     you | s/fish/snek/
kameloso | you | I am a snek
     you | !addquote you This is a quote
kameloso | Quote saved. (1 on record)
     you | !quote you
kameloso | you | This is a quote
     you | !note OfflinePerson Why so offline?
kameloso | Note added.
     you | !seen OfflinePerson
kameloso | I last saw OfflinePerson 1 hour and 34 minutes ago.
     you | kameloso: sudo PRIVMSG #channel :this is a raw IRC command
kameloso | this is a raw IRC command
     you | https://www.youtube.com/watch?v=s-mOy8VUEBk
kameloso | [youtube.com] Danish language (uploaded by snurre)
```

### Online help and commands

Send `help` to the bot in a private message for a summary of available bot commands, and `help [plugin] [command]` for a brief description of a specific one. Mind that commands defined as *regular expressions* cannot be shown, due to technical reasons.

The **prefix** character (here `!`) is configurable; refer to your generated configuration file. Common alternatives are `.` and `~`, making it `.note` and `~quote` respectively.

```ini
[Core]
prefix              !
```

It can technically be any string and not just one character. Enquote it if you want any spaces as part of the prefix, like `"please "` (making it `please note`, `please quote`, ...).

## Twitch

To connect to Twitch servers you must supply an [*OAuth token*](https://en.wikipedia.org/wiki/OAuth) *pass*. Generate one [here](https://twitchapps.com/tmi), then add it to your `kameloso.conf` in the `pass` field.

```ini
[IRCBot]
nickname            twitchaccount
pass                oauth:the50letteroauthstringgoeshere
homes               #twitchaccount
channels            #streamer1,#streamer2,#streamer3

[IRCServer]
address             irc.chat.twitch.tv
port                6667
```

See [the wiki](https://github.com/zorael/kameloso/wiki/Twitch) for more information.

### Twitch bot

There is a basic streamer bot plugin but it is opt-in, both during compilation and at runtime. Build the `twitch` configuration to compile it, and enable it in the configuration file under the `[TwitchBot]` section. If the section doesn't exist, regenerate the file after having compiled with the bot included. (It will not show up when generating the file if the plugin is not compiled in.)

```bash
$ dub build -c twitch
$ ./kameloso --writeconfig
```

 Assuming a prefix of `!`, commands to test are: `!uptime`, `!start`, `!stop`, `!oneliner`, `!commands`, `!vote`/`!poll`, `!admin`

 The `help` command does not work on Twitch.

## Use as a library

The IRC event parsing bits are largely decoupled from the bot parts of the program, needing only some common non-bot-oriented helper modules.

* [`irc/defs.d`](source/kameloso/irc/defs.d)
* [`irc/parsing.d`](source/kameloso/irc/parsing.d)
* [`irc/common.d`](source/kameloso/irc/common.d)
* [`string.d`](source/kameloso/string.d)
* [`conv.d`](source/kameloso/conv.d)
* [`meld.d`](source/kameloso/meld.d)
* [`traits.d`](source/kameloso/traits.d)
* [`uda.d`](source/kameloso/uda.d)

Feel free to copy these and drop them into your own project. Examples of parsing results can be found in [`tests/events.d`](source/tests/events.d). Look up the structs `IRCBot` and `IRCParser` to get started. See the versioning at the top of [`irc/common.d`](source/kameloso/irc/common.d). It can be slimmed down further if support for only a specific server network is required.

# Known issues

## Windows

Web URL lookup, including the web titles and Reddit plugins, will not work out of the box with secure HTTPS connections due to missing libraries. Download a "light" installer from [slproweb.com](https://slproweb.com/products/Win32OpenSSL.html) and install **to system libraries**, and it should no longer warn on program start.

Terminal colours may also not work, requiring a registry edit to make it display properly. This works for at least Windows 10.

* Under `HKEY_CURRENT_USER\Console`, create a `DWORD` named `VirtualTerminalLevel` and give it a value of `1`.
* Alternatively in Powershell: `Set-ItemProperty HKCU:\Console VirtualTerminalLevel -Type DWORD 1`
* Alternatively in `cmd`: `reg add HKCU\Console /v VirtualTerminalLevel /t REG_DWORD /d 1`

Otherwise use the `--monochrome` setting to disable colours, or compile a non-`colours` configuration.

Terminal output will be broken in Cygwin terminals without compiling the aforementioned `cygwin` configuration. Powershell and `cmd` consoles are unaffected.

When run in such Cygwin terminals, the bot will not gracefully shut down upon hitting Ctrl+C. Any changes to configuration will thus have to be otherwise saved prior to forcefully terminating like that.

## Posix

If the pipeline FIFO is removed while the program is running, it will hang upon exiting, requiring manual interruption with Ctrl+C. This is a tricky problem to solve, as it requires figuring out how to do non-blocking reads. Help wanted.

# Roadmap

* pipedream zero: **no compiler segfaults**
* pipedream: DCC
* pipedream two: `ncurses`?
* `seen` doing what? channel-split? `IRCEvent`-based? (later)
* private notes (later)
* non-blocking FIFO
* more pairs of eyes

# Built with

* [**D**](https://dlang.org)
* [`dub`](https://code.dlang.org)
* [`dlang-requests`](https://code.dlang.org/packages/requests)
* [`arsd`](https://github.com/adamdruppe/arsd)

# License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

# Acknowledgements

* [kameloso](https://www.youtube.com/watch?v=s-mOy8VUEBk) for obvious reasons
* [`README.md` template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [ikod](https://github.com/ikod) for [`dlang-requests`](https://github.com/ikod/dlang-requests)
* [Adam D. Ruppe](https://github.com/adamdruppe) for [`arsd`](https://github.com/adamdruppe/arsd)
* [`#d` on freenode](irc://irc.freenode.org:6667/#d)
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on freenode](irc://irc.freenode.org:6667/#ircdocs)

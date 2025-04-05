# kameloso [![Linux/macOS/Windows](https://img.shields.io/github/actions/workflow/status/zorael/kameloso/d.yml?branch=master&logo=github&maxAge=3600)](https://github.com/zorael/kameloso/actions?query=workflow%3AD) [![Linux](https://img.shields.io/circleci/project/github/zorael/kameloso/master.svg?logo=circleci&maxAge=3600)](https://circleci.com/gh/zorael/kameloso) [![Windows](https://img.shields.io/appveyor/ci/zorael/kameloso/master.svg?logo=appveyor&maxAge=3600)](https://ci.appveyor.com/project/zorael/kameloso) [![Commits since last release](https://img.shields.io/github/commits-since/zorael/kameloso/v3.14.159.svg?logo=github&maxAge=3600)](https://github.com/zorael/kameloso/compare/v3.14.159...master)

**kameloso** is an IRC bot.

### So what does it do

* real-time chat monitoring
* channel polls, user quotes, `!seen`, custom counters, oneliner commands, recurring announcements, [...](https://github.com/zorael/kameloso/wiki/Current-plugins)
* notes to offline users that get played back when they come online
* reporting titles of pasted links, YouTube video information
* `s/this/that/` substitution of messages
* [Twitch support](#twitch) with [several](#twitch-bot) common bot features
* logs
* bugs

All of the above [are runtime plugins](source/kameloso/plugins) and can be disabled or even omitted from compilation entirely. It is modular and easy to extend. A skeletal *Hello World* plugin is [less than 30 lines of code](source/kameloso/plugins/hello.d).

**Please report bugs. Unreported bugs can only be fixed by accident.**

### tl;dr

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
            --color Use colours in terminal output (auto|always|never)
             --save Write configuration to file
```

Prebuilt binaries for Windows and Linux can be found under [**Releases**](https://github.com/zorael/kameloso/releases). (64-bit only)

To compile it yourself:

```shell
$ dub run kameloso -- --server irc.libera.chat --homeChannels "#mychannel" --guestChannels "#d"

## alternatively, guaranteed latest
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
$ dub build
$ ./kameloso --server irc.libera.chat --homeChannels "#mychannel" --guestChannels "#d"
```

If there's anyone talking it should show on your screen.

---

## Table of contents

* [Getting started](#getting-started)
  * [Prerequisites](#prerequisites)
    * [Compiler versions](#compiler-versions)
    * [SSL libraries on Windows](#ssl-libraries-on-windows)
  * [Downloading source](#downloading-source)
  * [Compiling](#compiling)
    * [Compiler choice](#compiler-choice)
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
    * [Hostmasks](#hostmasks)
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
    * [OpenSSL](#openssl)
    * [Certificate authority bundle](#certificate-authority-bundle)
  * [YouTube song request playlist integration errors](#youtube-song-request-playlist-integration-errors)
* [Roadmap](#roadmap)
* [Built with](#built-with)
* [License](#license)
* [Acknowledgements](#acknowledgements)

---

## Getting started

Grab a prebuilt Windows or Linux binary from under [**Releases**](https://github.com/zorael/kameloso/releases) (64-bit only); alternatively, download the source and compile it yourself.

### Prerequisites

The program can be built using the [**D**](https://dlang.org) reference compiler [**dmd**](https://dlang.org/download.html), with the LLVM-based [**ldc**](https://github.com/ldc-developers/ldc/releases) and with the GCC-based [**gdc**](https://gdcproject.org/downloads). **dmd** offers *very* fast compilation, while **ldc** and **gdc** are both slower at compiling but produce faster code. The latter two additionally support more target architectures than **dmd** does (e.g. ARM). See [here](https://wiki.dlang.org/Compilers) for an overview of the available compiler vendors.

The package manager [**dub**](https://code.dlang.org) is used to facilitate compilation and dependency management. On Windows it is included in the compiler archive, while on Linux it may need to be installed separately. Refer to your repositories.

#### Compiler versions

Starting with `v4.0.0`, a more recent compiler version is required. This is to allow for use of named arguments and to enable some compiler preview switches.

You need a compiler based on D version **2.108** or later (April 2024). For **ldc** this translates to a minimum of version **1.38**. It's not easy to find information on **gdc** versions, but **14.2** is known to be recent enough.

If your repositories (or other software sources) don't have compilers recent enough, you can use the official [`install.sh`](https://dlang.org/install.html) installation script to download current ones, or any version of choice. (**gdc** is not available via this script.)

Releases of the bot prior to `v4.0.0` remain available for older compilers.

#### SSL libraries on Windows

See the [known issues](#windows) section for extra steps required to create secure connections.

(**tl;dr**: Run the program with [`--get-openssl`](#openssl) and [`--get-cacert`](#certificate-authority-bundle) to download what is needed as a one-time setup.)

### Downloading source

```shell
git clone https://github.com/zorael/kameloso.git
```

It can also be downloaded as a [`.zip` archive](https://github.com/zorael/kameloso/archive/master.zip).

### Compiling

```shell
dub build
```

This will compile the bot in the default **debug** build type, which adds some extra code and debugging symbols. You can omit these and have the compiler perform some optimisations by building it in **release** mode, by calling `dub build -b release`. Mind that build times will increase.

Refer to the output of `dub --annotate --print-builds` for more build types.

#### Compiler choice

It is recommended that you use **ldc** for release builds.

* **gdc** is very slow to compile (but is not otherwise a poor choice).
* **ldc** optimisations are *objectively* better than those of **dmd**.

Specify which compiler you want to use with the `--compiler` switch. You may have to refer to **ldc** as **ldc2** on some systems.

#### Build configurations

There are two primary configurations in which the bot may be built.

* `application` is the base configuration
* `twitch` additionally includes the Twitch plugin and the required support for Twitch servers

Both configurations come in `-lowmem` variants; `application-lowmem` and `twitch-lowmem`; that lower compilation memory required at the cost of increased build times. This may help on memory-constrained systems, such as the Raspberry Pi.

List configurations with `dub --annotate --print-configs`. You can specify which to compile with the `-c` switch. Not supplying one will make it build the default `application` configuration.

```shell
dub build -c twitch
```

If you want to trim down the program and customise your own build to only compile the plugins you want to use, see the larger `versions` lists in `dub.sdl`. Simply add a character to the lines corresponding to the plugins you want to omit, thus invalidating the version identifiers and effectively disabling the code they relate to. Mind that disabling any of the **_\*Service_** plugins may/will break the bot in subtle ways. All other plugins are completely optional.

## How to use

### Configuration

The bot ideally wants the [*services account name*](#except-nothing-happens) of one or more administrators of the bot, and/or more importantly one or more *home* channels to operate in. Without either it's just a read-only log bot, which is admittedly also a completely valid and fully-supported use-case, but it's probably not what you want.

To define these you can either supply them on the command line by use of flags listed by calling the program with `--help`, or by generating a configuration file with `--save` and entering them in there.

```shell
./kameloso --save
```

A new `kameloso.conf` will be created in a directory dependent on your platform.

#### Configuration file

* **Linux** and other Posix: `$HOME/.config/kameloso/` (overridden by `$XDG_CONFIG_HOME`)
* **Windows**: `%APPDATA%\kameloso\`
* **macOS**: `$HOME/Library/Preferences/kameloso/`

Open the file in your text editor of choice.

As a shortcut you can pass `--gedit` to attempt to automatically open it in a **g**raphical **edit**or, or `--edit` to open it in your default terminal one, as defined in the `$EDITOR` environment variable (where available).

#### Command-line arguments

You can make changes to your configuration file in-place by specifying some settings at the command line at the same time as `--save`.

```shell
$ ./kameloso \
    --server irc.libera.chat \
    --nickname "mybot" \
    --admins "me" \
    --homeChannels "#mychannel" \
    --guestChannels "#d,##networking" \
    --color=never \
    --save

[12:34:56] Configuration written to /home/user/.config/kameloso/kameloso.conf
```

Settings not touched will keep their values, but any comments in the file will be lost.

#### Display settings

Text colours are by default set to go well with terminal themes with dark backgrounds. If you instead have a bright background theme, text may be difficult to read (e.g. white on white), depending on your terminal emulator program. If so, try passing the `--bright` argument, or modify the configuration file and enable `brightTerminal` under `[Core]` to make the setting persistent.

If only some colours work, try limiting colouring some by disabling `extendedColours`, also under `[Core]`. If one or more colours are still too dark or too bright even with the right `brightTerminal` setting, please refer to your terminal appearance settings.

An alternative is to disable colours with `--color=never`.

#### Other files

More server-specific resource files will be created the first time you connect to a server. Where these are placed is platform-dependent.

* **Linux** and other Posix: `$HOME/.local/share/kameloso/` (overridden by `$XDG_DATA_HOME`)
* **Windows**: `%LOCALAPPDATA%\kameloso\`
* **macOS**: `$HOME/Library/Application Support/kameloso/`

### Example use

Refer to [the wiki](https://github.com/zorael/kameloso/wiki/Current-plugins) for more information on available plugins and their commands. Additionally, see [this section about permissions](#except-nothing-happens) if nothing happens when you try to invoke commands.

```
      you joined #channel
 kameloso sets mode +o you

      <you> I am a fish
      <you> s/fish/snek/
 <kameloso> you | I am a snek

    <blarf> I am a snek too
      <you> !addquote blarf I am a snek too
 <kameloso> Quote added at index #4.
      <you> !quote blarf
 <kameloso> I am a snek too (blarf #4 2022-04-04)
      <you> !quote blarf #3
 <kameloso> A Møøse once bit my sister (blarf #3 2022-02-01)
      <you> !quote blarf barnes and noble
 <kameloso> i got kicked out of barnes and noble once for moving all the bibles into the fiction section (blarf #0 2019-08-21)

      <you> !seen
 <kameloso> Usage: !seen [nickname]
      <you> !seen MrOffline
 <kameloso> I last saw MrOffline 1 hour and 34 minutes ago.

 <MsOnline> !note
 <kameloso> Usage: !note [nickname] [note text]
 <MsOnline> !note MrOffline About the thing you mentioned, yeah no
 <kameloso> Note added.
 MsOnline left #channel
MrOffline joined #channel
 <kameloso> MrOffline! MsOnline left note 4 hours and 28 minutes ago: "About the thing you mentioned, yeah no"

      <you> !operator add bob
 <kameloso> Added BOB as an operator in #channel.
      <you> !whitelist add alice
 <kameloso> Added Alice as a whitelisted user in #channel.
      <you> !blacklist del steve
 <kameloso> Removed steve as a blacklisted user in #channel.

      <you> !automode
 <kameloso> Usage: !automode [add|clear|list] [nickname/account] [mode]
      <you> !automode add ray +o
 <kameloso> Automode modified! ray on #channel: +o
      ray joined #channel
 kameloso sets mode +o ray

      <you> !oneliner new
 <kameloso> Usage: !oneliner new [trigger] [type] [optional cooldown]
      <you> !oneliner new info random
 <kameloso> Oneliner !info created! Use !oneliner add to add lines.
      <you> !oneliner add info @$nickname: for more information just use Google
 <kameloso> Oneliner line added.
      <you> !oneliner add info @$nickname: for more information just use Bing
 <kameloso> Oneliner line added.
      <you> !oneliner new vods ordered
 <kameloso> Oneliner !vods created! Use !oneliner add to add lines.
      <you> !oneliner add vods See https://twitch.tv/zorael/videos for $streamer's on-demand videos (stored temporarily)
 <kameloso> Oneliner line added.
      <you> !oneliner new source ordered
 <kameloso> Oneliner !source created! Use !oneliner add to add lines.
      <you> !oneliner add source I am $bot. Peruse my source at https://github.com/zorael/kameloso
 <kameloso> Oneliner line added.
      <you> !info
 <kameloso> @you: for more information just use Google
      <you> !info
 <kameloso> @you: for more information just use Bing
      <you> !oneliner modify
 <kameloso> Usage: !oneliner modify [trigger] [type] [optional cooldown]
      <you> !oneliner modify info random 10
 <kameloso> Oneliner !info modified to type random, cooldown 10 seconds
      <you> !vods
 <kameloso> See https://twitch.tv/zorael/videos for Channel's on-demand videos (stored temporarily)
      <you> !oneliner alias
 <kameloso> Usage: !oneliner alias [trigger] [existing trigger to alias]
      <you> !oneliner alias vods vod
 <kameloso> Oneliner !vod created as an alias to !vods!.
      <you> !vod
 <kameloso> See https://twitch.tv/zorael/videos for Channel's on-demand videos
      <you> !commands
 <kameloso> Available commands: !info, !vods, !source
      <you> !oneliner del vods
 <kameloso> Oneliner !vods removed.

      <you> !timer new
 <kameloso> Usage: !timer new [name] [type] [condition] [message threshold] [time threshold] [stagger message count] [stagger time]
      <you> !timer new mytimer ordered both 100 600 0 0
 <kameloso> New timer added! Use !timer add to add lines.
      <you> !timer add mytimer This is an announcement on a timer
 <kameloso> Line added to timer mytimer.
      <you> !timer add mytimer It is sent after 100 messages have been seen *AND* 600 seconds have passed
 <kameloso> Line added to timer mytimer.
(...time passes with activity in chat...)
 <kameloso> This is an announcement on a timer
(...time passes with activity in chat...)
 <kameloso> It is sent after 100 messages have been seen *AND* 600 seconds have passed
      <you> !timer suspend mytimer
 <kameloso> Timer suspended. Use !timer resume mytimer to resume it.
      <you> !timer resume mytimer
 <kameloso> Timer resumed!
      <you> !timer modify
 <kameloso> Usage: !timer modify [name] [type] [condition] [message count threshold] [time threshold] [stagger message count] [stagger time]
      <you> !timer modify mytimer random either 500 1h 50 5m
 <kameloso> Timer "mytimer" modified to type random, condition either, message threshold 500, time threshold 3600 seconds, stagger message count 50, stagger time 300 seconds

      <you> !poll
 <kameloso> Usage: !poll [seconds] [choice1] [choice2] ...
      <you> !poll 2m snik snek
 <kameloso> Voting commenced! Please place your vote for one of: snek, snik (2 minutes)
      <BOB> snek
    <Alice> snek
      <ray> snik
 <kameloso> Voting complete, results:
 <kameloso> snek : 2 (66.6%)
 <kameloso> snik : 1 (33.3%)

      <you> https://github.com/zorael/kameloso
 <kameloso> [github.com] GitHub - zorael/kameloso: IRC bot
      <you> https://youtu.be/ykj3Kpm3O0g
 <kameloso> [youtube.com] Uti Vår Hage - Kamelåså (HD) (uploaded by Prebstaroni)

(context: playing a video game)
      <you> !counter
 <kameloso> Usage: !counter [add|del|format|list] [counter word]
      <you> !counter add deaths
 <kameloso> Counter deaths added! Access it with !deaths.
      <you> !deaths+
 <kameloso> deaths +1! Current count: 1
      <you> !deaths+3
 <kameloso> deaths +3! Current count: 4
      <you> !deaths
 <kameloso> Current deaths count: 4
      <you> !deaths=0
 <kameloso> deaths count assigned to 0!
      <you> !counter format
 <kameloso> Usage: !counter format [counter word] [one of ?, +, - and =] [format pattern]
      <you> !counter format deaths ? strimmer has so far died $count times! D:
 <kameloso> Format pattern updated.
      <you> !counter format deaths + oh no, another death!
 <kameloso> Format pattern updated.
      <you> !deaths+
 <kameloso> oh no, another death!
      <you> !deaths+
 <kameloso> oh no, another death!
      <you> !deaths
 <kameloso> strimmer has so far died 2 times! D:
      <you> !counter format deaths ? -
 <kameloso> Format pattern cleared.

      <you> !stopwatch start
 <kameloso> Stopwatch started!
      <you> !stopwatch
 <kameloso> Elapsed time: 18 minutes and 42 seconds
      <you> !stopwatch stop
 <kameloso> Stopwatch stopped after 1 hour, 48 minutes and 10 seconds.

      <you> !time
 <kameloso> The time is currently 11:04 locally.
      <you> !time Europe/London
 <kameloso> The time is currently 10:04 in Europe/London.
      <you> !time Tokyo
 <kameloso> The time is currently 18:05 in Tokyo.
      <you> !setzone Helsinki
 <kameloso> Timezone changed to Europe/Helsinki.
      <you> !time
 <kameloso> The time is currently 12:05 in Europe/Helsinki.
```

#### Online help and commands

Use the `!help` command of the [**Help**](https://github.com/zorael/kameloso/wiki/Current-plugins#help) plugin for a summary of available bot commands, and `!help [plugin] [command]` for a brief description of a specific one. The shorthand `!help !command` also works.

The *command prefix* (here "`!`") is configurable; refer to your configuration file. Common alternatives are `.` (dot), `~` (tilde) and `?`, making it `.note`, `~quote` and `?counter` respectively.

```ini
[Core]
prefix                      "!"
```

It can technically be any string and not just one character. It may include spaces if enclosed within quotes.

Additionally, prefixing commands with the bot's nickname also always works, as in `kameloso: seen MrOffline`. Some commands require it. If no command prefix is set, commands may only be invoked by prefixing them with the nickname this way.

#### ***Except nothing happens***

Before allowing *anyone* to trigger *any* restricted functionality, the bot will try to identify the accessing user by querying the server for what [*services account*](https://en.wikipedia.org/wiki/IRC_services) that user is logged onto, if not already known. For full and global administrative privileges, you will need to be logged into services with an account listed in the `admins` field in the configuration file. Other users may have permissions defined per-channel in the [`users.json`](#other-files) file, placed in your resource directory. These can also be managed online by commands provided by the [**Admin**](https://github.com/zorael/kameloso/wiki/Current-plugins#admin) plugin.

If a user is not logged onto services, they are considered as not being uniquely identifiable, and thus cannot be resolved to an account.

#### Hostmasks

Not all servers offer services, and in those cases you can enable [*hostmasks mode*](https://github.com/zorael/kameloso/wiki/On-servers-without-services-(e.g.-no-NickServ)). This is a weaker solution to user identification, but it's better than nothing if services aren't available. With it enabled, the above still applies but "accounts" are derived from user hostmasks.

See the `!hostmask` command of the same [**Admin**]((https://github.com/zorael/kameloso/wiki/Current-plugins#admin)) plugin (and the [`hostmasks.json`](#other-files) resource file) for how to map hostmasks to would-be accounts.

### **Twitch**

> **If you're interested in trying the bot but don't want to run it yourself, [contact me](mailto:zorael@gmail.com?subject=Hosting+a+kameloso+instance) and I will host an instance for you on a headless server.**

#### **Copy paste-friendly concrete setup from scratch**

Prebuilt binaries for Windows and Linux can be found under [**Releases**](https://github.com/zorael/kameloso/releases) (64-bit only).

```shell
./kameloso --setup-twitch
```

The `--setup-twitch` flag creates a configuration file with the server address and port already set to connect to Twitch, then opens it up in a text editor.

On Windows it additionally downloads and launches an installer for [**OpenSSL for Windows**](#openssl) as well as downloads a [**certificate authority bundle**](#certificate-authority-bundle) file, both of which are [required](#windows) to create secure connections. Make sure to choose to *install to Windows system directories* when asked.

**A line with a leading `#` is disabled, so remove any `#`s from the start of lines you want to enable.**

* Add your channel to `homeChannels`. Channel names are account names (which are always lowercase) with a `#` in front, so the Twitch user `streamer123_jp` with a display name of `配信者` would have the channel `#streamer123_jp`.
* Optionally add one or more account names to the list of `admins` to give them global low-level control of the bot. Owners of channels (broadcasters) automatically have high privileges in the scope of their own channels, so it's not strictly needed for general use, but it may be a good idea to have while you're setting things up.
* You can ignore `nickname`, `user`, `realName`, `account` and `password`, as they're not applicable on Twitch. *Do not enter your Twitch password **anywhere** in this file.*
* Peruse the file for other settings if you want; you can always get back to it by passing `--gedit` (short for **g**raphical **edit**or).

The program can then be run normally, though a few preparatory steps remain.

```shell
./kameloso
```

It should now start a terminal wizard requesting a new *authorisation token*, upon detecting it's missing one. If it doesn't, force it with `--set twitch.keygen`. See the [long story](#long-story) section below for details.

**Note that it will request a token for the user you are currently logged in as in your browser**. If you want one for a different **bot user** instead, open up a private/incognito window and log into Twitch normally *with the bot account* there. Copy the address of the page it opened for your other account ([this link](https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=tjyryd2ojnqr8a51ml19kn1yi2n0v1&redirect_uri=http://localhost&scope=moderator:manage:chat_messages+moderator:manage:banned_users+user:manage:whispers+channel:moderate+chat:edit+chat:read+whispers:edit+whispers:read+moderator:read:followers+user:read:follows&force_verify=true&state=kameloso)), then follow it in that browser window instead. Refer to the terminal instructions again to continue.

After obtaining a token and verifying it, it will save it to your configuration file and reconnect to the server. Provided there were no errors, the bot should now enter your channel. Say something in your chat in your browser and it should show in your terminal. If there were errors or snags, or if something was simply unintuitive, [please file an issue](https://github.com/zorael/kameloso/issues/new) so the process can be improved upon.

If you don't like the terminal colours, `--color=never` disables them.

#### Example configuration

```ini
[IRCClient]
nickname                    doesntmatter
user                        ignored
realName                    likewise

[IRCBot]
#account
#password                   (ignore; do NOT enter your Twitch account password!)
pass                        (twitch.keygen authorisation token for bot account)
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
watchtimeExcludesLurkers    true
songrequestMode             youtube
songrequestPermsNeeded      whitelist
mapWhispersToChannel        false
promoteBroadcasters         true
promoteModerators           true
promoteVIPs                 true
workerThreads               3
```

The port to use for secure connections is **6697** (or rarely **443**). For a non-encrypted connection, while heavily discouraged, use the default port **6667**.

#### **Long story**

To connect to Twitch servers, you must first compile the `twitch` build configuration to include Twitch support. **All pre-compiled binaries available from under [Releases](https://github.com/zorael/kameloso/releases) are already built this way.**

You will also require an [*authorisation token*](https://en.wikipedia.org/wiki/OAuth). Assuming you have a configuration file set up to connect to Twitch, such as with `--setup-twitch`, it will automatically start a terminal wizard requesting one on program startup, **if** none is present. Run the bot with `--set twitch.keygen` to force it if it doesn't, which it won't if you already have a token and it merely expired. (They last about 60 days.)

If you are not already logged into Twitch in your browser, it will open a browser window with the Twitch login page. Verify that it's truly Twitch by checking the page address; it should end with `.twitch.tv`, with the little lock symbol showing the connection is secure.

> Do note that at no point is the bot privy to your Twitch login credentials! The logging-in is wholly done on Twitch's own servers, and no information is sent to any third parties. The code that deals with all this is open for audit; [`requestTwitchKey` in `plugins/twitch/providers/twitch.d`](source/kameloso/plugins/twitch/providers/twitch.d).

Logging in should lead you to a page where you must authorise the bot to perform certain actions on behalf of your (bot) account, such as reading and sending messages, performing moderator actions, etc.

Click **Authorize** and you will be redirected to an empty "`this site can't be reached`" or "`unable to connect`" page. **Copy the URL address** of that page and **paste** it into the terminal, which you should be prompted to do. Hit enter and it will parse the address, extract your authorisation token, verify it, save it to your configuration file, and then finally connect to the server.

If you prefer to generate the token manually, [here is the URL you need to follow](https://id.twitch.tv/oauth2/authorize?response_type=token&client_id=tjyryd2ojnqr8a51ml19kn1yi2n0v1&redirect_uri=http://localhost&scope=moderator:manage:chat_messages+moderator:manage:banned_users+user:manage:whispers+channel:moderate+chat:edit+chat:read+whispers:edit+whispers:read+moderator:read:followers+user:read:follows&force_verify=true&state=kameloso). The key generation wizard only opens it for you, as well as automates saving the resulting token to your configuration file (as `pass` under `[IRCBot]`).

Mind that the authorisation token should still be kept secret. It's not possible to derive your Twitch account password from it, but anyone with access to it can chat as if they were you. This is part of why it's recommended to use a bot account instead.

#### Twitch bot

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
* `!shoutout`
* `!startpoll`/`!endpoll` (*highly* experimental and unlikely to work until we can perform some live testing, which requires the help of a Twitch affiliate)
* `!commercial` (also requires affiliate testing)
* `!subs`

...alongside `!oneliner`, `!counter`, `!timer`, `!poll` (chat variant), `!time`, `!stopwatch`, and other non-Twitch-specific commands. Try `!help` or [the wiki](https://github.com/zorael/kameloso/wiki/Current-plugins).

Note that `.` (dot) and `/` (slash) prefixes will not work on Twitch.

##### Song requests

To be able to serve song requests, you will need to register an *application* to interface with [Google (YouTube)](https://console.cloud.google.com/projectcreate) and/or [Spotify](https://developer.spotify.com/dashboard) servers individually. To initiate the wizards for this, pass `--set twitch.googleKeygen` for YouTube and `--set twitch.spotifyKeygen` for Spotify, and follow the on-screen instructions. (They behave much like `--set twitch.keygen`.)

You may set up access tokens for both song request providers, but only one provider may be enabled at any one time. To control which, set `songrequestMode` to either `youtube` or `spotify` in your configuration file (under `[Twitch]`). A value of `disabled` disables the feature.

##### Certain commands require higher permissions

Some functionality, such as setting the channel title or currently played game, require elevated credentials with the permissions of the channel owner (broadcaster), as opposed to those of any moderator. If you want to use such commands, you will need to generate a separate authorisation token for *your main account*, much as you generated one to be able to connect with the bot account.

```shell
./kameloso --set twitch.superKeygen
```

This will request a token from Twitch with different permissions, and the authorisation browser page should reflect this.

Mind that you need to be logged into Twitch (in your browser) with your *main (broadcaster) account* while doing this, or the token obtained will be with permissions for the wrong channel. This is in contrast to `--set twitch.keygen`, with which it is recommended you use a separate bot account with only moderator status.

All keygens can be triggered at the same time, but care must be taken which account you are logged into when you click the respective `Authorize` buttons; you want the bot account for the normal `twitch.keygen` and the broadcaster account for `twitch.superKeygen`.

```shell
./kameloso \
    --set twitch.keygen \
    --set twitch.superKeygen \
    --set twitch.googleKeygen \
    --set twitch.spotifyKeygen
```

### Further help

For more information and help, first refer to [the wiki](https://github.com/zorael/kameloso/wiki).

If you still can't find what you're looking for, or if you have suggestions on how to improve the bot, you can...

* ...start a thread under [Discussions](https://github.com/zorael/kameloso/discussions).
* ...file a [GitHub issue](https://github.com/zorael/kameloso/issues/new).

## Known issues

### Windows

#### OpenSSL

The dependency we use to create secure connections in turn requires [**OpenSSL**](https://www.openssl.org) to be installed. It is *the* standard library for such on every major platform -- except for Windows, which has its own solution in the form of Windows Secure Channel. Help is needed to support that.

Run the program with the `--get-openssl` flag to download and launch the installer for [**OpenSSL for Windows v3.\* _(Light)_**](https://slproweb.com/products/Win32OpenSSL.html). When asked, make sure to opt to *install to Windows system directories*. This only needs to be done once.

#### Certificate authority bundle

Said dependency does not have the ability to retrieve certificates from Windows' own certificate storage, so in addition to the system-wide installation of **OpenSSL**, you will also need a *certificate authority bundle* file. Pass `--get-cacert` on the command line and the program will download a copy of [`cacert.pem`](https://curl.se/ca/cacert.pem), as extracted from Mozilla Firefox [by the **curl** project](https://curl.se/docs/caextract.html). It will be saved next to your configuration file.

You can pass both `--get-openssl` and `--get-cacert` at the same time for a one-time setup.

### YouTube song request playlist integration errors

If you're seemingly doing everything right and you still get permissions errors when attempting to add a YouTube video clip to a playlist, redo the Google keygen. When you're asked to pick one of your accounts late in the process, make sure that you select a *YouTube account*, as opposed to an overarching *Google account*. It should say **YouTube** underneath the option.

## Roadmap

* please send help: Windows Secure Channel SSL
* **more pairs of eyes**; if you don't test it, it's broken

## Built with

* [**D**](https://dlang.org)
* [`dialect`](https://github.com/zorael/dialect) ([dub](https://code.dlang.org/packages/dialect))
* [`lu`](https://github.com/zorael/lu) ([dub](https://code.dlang.org/packages/lu))
* [`requests`](https://github.com/ikod/dlang-requests) ([dub](https://code.dlang.org/packages/requests))

## License

This project is licensed under the **Boost Software License 1.0** - see the [LICENSE_1_0.txt](LICENSE_1_0.txt) file for details.

## Acknowledgements

* [Kamelåså](https://youtu.be/ykj3Kpm3O0g)
* [`#d` on Libera.Chat](irc://irc.libera.chat:6697/#d)
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on Libera.Chat](irc://irc.libera.chat:6667/#ircdocs)

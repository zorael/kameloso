# kameloso [![CircleCI Linux/OSX](https://img.shields.io/circleci/project/zorael/kameloso/master.svg?maxAge=3600)](https://circleci.com/gh/zorael/kameloso) [![Travis Linux/OSX and documentation](https://img.shields.io/travis/zorael/kameloso.svg?logo=travis)](https://travis-ci.org/zorael/kameloso) [![Windows](https://img.shields.io/appveyor/ci/zorael/kameloso.svg?maxAge=3600&logo=appveyor)](https://ci.appveyor.com/project/zorael/kameloso) [![Issue 46](https://img.shields.io/github/issues/detail/s/zorael/kameloso/46.svg)](https://github.com/zorael/kameloso/issues/46) [![GitHub tag](https://img.shields.io/github/tag/zorael/kameloso.svg?maxAge=3600&logo=github)](#)

**kameloso** sits and listens in the channels you specify and reacts to events, like bots generally do.

It is written in [**D**](https://www.dlang.org). A variety of features comes bundled in the form of plugins, and it's very easy to write your own. Any and all ideas welcome. API documentation is [available online](https://zorael.github.io/kameloso).

It works well with the majority of server networks. IRC is standardised but servers still come in [many flavours](https://upload.wikimedia.org/wikipedia/commons/thumb/d/d5/IRCd_software_implementations3.svg/1533px-IRCd_software_implementations3.svg.png), where some [outright conflict](http://defs.ircdocs.horse/defs/numerics.html) with others. If something doesn't immediately work it's most often an easy issue of specialcasing for that particular IRC network or server daemon.

### Current functionality includes:

* bedazzling coloured terminal output like it's the 90s
* automatic mode sets (eg. auto `+o` for op)
* looking up titles of pasted web URLs
* `sed`-replacement of the last message sent (`s/this/that/` substitution)
* saving `notes` to offline users that get played back when they come online
* [`seen`](https://github.com/zorael/kameloso/blob/master/source/kameloso/plugins/seen.d) plugin; reporting when a user was last seen, written as a rough example plugin
* user `quotes` plugin
* Reddit post lookup
* [`bash.org`](http://bash.org) quoting
* Twitch support; Twitch bot is now easy (see notes on connecting below)
* piping text from the terminal to the server (Posix only)
* mIRC colour coding and text effects (bold, underlined, ...), translated into Bash terminal formatting
* [SASL](https://en.wikipedia.org/wiki/Simple_Authentication_and_Security_Layer) authentication (`plain`)

### Current limitations:

* **the dmd and ldc compilers may segfault** if building in anything other than `debug` mode (bug [#18026](https://issues.dlang.org/show_bug.cgi?id=18026), see more on build types below).
* the **gdc** compiler doesn't yet support `static foreach` and thus cannot be used to build this bot.
* some plugins don't yet differentiate between different home channels if there is more than one.
* nicknames are not yet case-insensitive. The `lowercaseNickname` function is in place; it's just not yet seeing wide use. It is a very invasive change, so holding out until we find a usecase.
* quirky IRC server daemons that have not been tested against may exhibit weird behaviour if parsing goes awry. Need concrete examples to fix; please report abnormalities, like error messages, or fields silently having wrong or no values.

Use on networks without [*services*](https://en.wikipedia.org/wiki/IRC_services) (`NickServ`/`Q`/`AuthServ`/...) may be difficult, since the bot identifies people by their account names. You will probably want to register yourself with such, where available.

Testing is mainly done on [**freenode**](https://freenode.net), so support and coverage is best there.

# Table of contents

* [News](#news)
* [Getting started](#getting-started)
    * [Prerequisites](#prerequisites)
    * [Downloading](#downloading)
    * [Compiling](#compiling)
        * [Windows](#windows)
* [How to use](#how-to-use)
    * [Twitch](#twitch)
    * [Use as a library](#use-as-a-library)
* [Debugging and generating unit tests](#debugging-and-generating-unit-tests)
* [Roadmap](#roadmap)
* [Built with](#built-with)
    * [License](#license)
    * [Acknowledgements](#acknowledgements)
---

# News

* compiler segfaults are back.
* experimental `automodes` plugin, please test.
* the `printer` plugin can now save logs to disk. Regenerate your configuration file and enable it with `saveLogs` set to `true`. It can either write lines as they are received, or buffer writes to write with a cadence of once every PING, configured with `bufferedWrites`. By default only homes are logged; configurable with the `logAllChannels` knob. Needs testing and feedback.
* all* (non-service) plugins can now be toggled as enabled or disabled in the configuration file. Regenerate it to get the needed entries.
* `IRCEvent` now has a new field; `count`. It houses counts, amounts, the number of times something has happened, and similar numbers. This lets us leave `num` alone to its original purpose of specifying numerics.
* `--asserts` vastly improved.
* Twitch emote highlighting; now uses a `dstring` and is seemingly fully accurate.

# Getting started

These instructions will get you a copy of the project up and running on your local machine for development and testing purposes, as well as general use.

## Prerequisites

You need a **D** compiler and the official [**dub**](https://code.dlang.org/download) package manager. There are three compilers available; see [here](https://wiki.dlang.org/Compilers) for an overview. You need one based on version **2.076** or later (released September 2017).

**kameloso** can be built using the reference compiler [**dmd**](https://dlang.org/download.html) and the LLVM-based [**ldc**](https://github.com/ldc-developers/ldc/releases), in `debug` mode (see below). The GCC-based [**gdc**](https://gdcproject.org/downloads) is currently too old to be used.

It's *possible* to build it manually without dub, but it is non-trivial if you want the web-related plugins to work.

## Downloading

GitHub offers downloads in [ZIP format](https://github.com/zorael/kameloso/archive/master.zip), but it's arguably easier to use **git** and clone a copy of the source that way.

```bash
$ git clone https://github.com/zorael/kameloso.git
$ cd kameloso
```

## Compiling

```bash
$ dub build
```

This will compile it in the default `debug` *build type*, which adds some extra code and debugging symbols.

> You can automatically strip these and add some optimisations by building it in `release` mode with `dub build -b release`. Mind that build times will increase. Refer to the output of `dub build --help` for more build types.

The above may currently not work, as the compiler will crash on some build configurations under anything other than `debug` mode.

Unit tests are built into the language, but you need to compile the project in `unittest` mode to include them.

```bash
$ dub build -b unittest
```

The tests are run at the *start* of the program, not during compilation. You can use the shorthand `dub test` to compile with tests and run them in one go. `unittest` builds will only run the unit tests and immediately exit.

The available *build configurations* are:

* `vanilla`, builds without any specific extras
* `colours`, compiles in terminal colours
* `web`, compiles in plugins with web lookup (`webtitles`, `reddit` and `bashquotes`)
* `colours+web`, includes both of the above
* `posix`, default on Posix-like systems, equals `colours+web`
* `windows`, default on Windows, equals `web`
* `cygwin`, equals `colours+web` but with extra code needed for running it under the default Cygwin terminal (*mintty*)

You can specify which to compile with the `-c` switch. Not supplying one will make it build the default for your operating system.

```bash
$ dub build -c cygwin
```

## Windows

There are a few Windows caveats.

* Web URL lookup, including the web titles and Reddit plugins, may not work out of the box with secure HTTPS connections due to the default installation of `dlang-requests` not finding the correct libraries. Unsure of how to fix this. Normal HTTP access should work fine.
* Terminal colours may also not work, depending on your version of Windows and likely your terminal font. Unsure of how to enable this.
* Use in Cygwin terminals without compiling the aforementioned `cygwin` build configuration will be unpleasant. Normal `cmd` and Powershell consoles are not affected and can be used with any configuration.

# How to use

The bot needs the services account name of the administrator(s) of the bot, and/or one or more home channels to operate in. It cannot work without having at least one of the two, so you need to generate and edit a configuration file before starting.

```bash
$ ./kameloso --writeconfig
```

Open the new `kameloso.conf` in a text editor and fill in the fields. Additional resource files will have been created as well; for instance, see `users.json` for where to enter whitelisted (and blacklisted) account names.

If you enter an authentification password (`authPassword`) and then regenerate the file, the password will be encoded into **Base64** format. Mind that this does not mean it's encrypted! It just makes it less easy to tell what the password is at a mere glance.

Once the bot has joined a home channel, it's ready. Mind that you need to authorise yourself with services with an account listed as an administrator in the configuration file to make it listen to anything you do. Before allowing *anyone* to trigger any functionality it will look them up and compare their accounts with its white- and blacklists.

```
     you joined #channel
kameloso sets mode +o you
     you | !say foo
kameloso | foo
     you | foo bar baz
     you | s/bar/BAR/
kameloso | you | foo BAR baz
     you | !8ball
kameloso | It is decidedly so
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
     you | !bash 85514
kameloso | <Reverend> IRC is just multiplayer notepad.
     you | https://www.youtube.com/watch?v=s-mOy8VUEBk
kameloso | [youtube.com] Danish language
     you | !reddit https://dlang.org/blog/2018/01/04/dmd-2-078-0-has-been-released/
kameloso | Reddit post: https://www.reddit.com/r/programming/comments/7o2tcw/dmd_20780_has_been_released
```

Send `help` to the bot in a private message for a summary of available bot commands, and `help [plugin] [command]` for a brief description of a specific one. Mind that commands defined as *regular expressions* cannot be shown, due to technical reasons.

The *prefix* character (here "`!`") is configurable; refer to your generated configuration file. Common alternatives are `.` and `~`, making it `.note` and `~quote` respectively.

```ini
[Core]
prefix              !
```

It can technically be any string and not just one character. Enquote it if you want any spaces as part of the prefix token, like `"please "`.

If you have compiled in colours and you have bright terminal background, the colours may be hard to see and the text difficult to read. If so, make sure to pass the `--bright` argument, and/or modify the configuration file; `brightTerminal` under `[Core]`. The bot uses the entire range of [8-colour ANSI](https://en.wikipedia.org/wiki/ANSI_escape_code#3/4_bit), so if one or more colours are too dark or bright even with the right `brightTerminal` setting, please see to your terminal appearance settings. This is not uncommon, especially with backgrounds that are not fully black or white. (read: Monokai, Breeze, Solaris, ...)

## Twitch

To connect to Twitch servers you must supply an [*OAuth token*](https://en.wikipedia.org/wiki/OAuth). Generate one [here](https://twitchapps.com/tmi), then add it to your `kameloso.conf` in the `pass` field.

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

`pass` is not the same as `authPassword`. It is supplied very early during login (or *registration*) to allow you to connect -- even before negotiating username and nickname, which is otherwise the very first thing to happen. `authPassword` is something that is sent to a services bot (like `NickServ` or `AuthServ`) after registration has finished and you have successfully logged onto the server. (In the case of SASL authentication, `authPassword` is used during late registration.)

## Use as a library

The IRC event parsing bits are largely decoupled from the rest of the program, needing only some helper modules.

* [`irc.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/irc.d)
* [`ircdefs.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/ircdefs.d)
* [`string.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/string.d)
* [`meld.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/meld.d)
* [`uda.d`](https://github.com/zorael/kameloso/blob/master/source/kameloso/uda.d)

Feel free to copy these and drop them into your own project.

# Debugging and generating unit tests

Writing an IRC bot when servers all behave differently is a game of whack-a-mole. As such, you may/will come across unexpected events for which there are no rules on how to parse. It may be some messages silently have weird values in the wrong fields (e.g. nickname where channel should go), or be empty when they shouldn't -- or more likely there will be an error message. Please file an issue.

If you're working on developing the bot yourself, you can generate unit test assert blocks for new events by passing the command-line `--asserts` flag, specifying the server daemon and pasting the raw line. Copy the generated assert block and place it in `tests/events.d`, or wherever is appropriate.

If more state is neccessary to replicate the environment, such as needing things from `RPL_ISUPPORT` or a specific resolved server address (from early `NOTICE` or `RPL_HELLO`), paste/fake the raw line for those first and it will inherit the implied changes for any following lines throughout the session. It will print the changes for easier construction of unit tests, so you'll know if you suceeded.

# Roadmap

* pipedream zero: no compiler segfaults
* pipedream: DCC
* pipedream two: `ncurses`
* optional formatting in IRC output? (later if at all)
* notes triggers? (later)
* `seen` doing what? channel-split? `IRCEvent`-based? (later)
* set up a real configuration home like `~/.kameloso`? what of Windows?
* automode channel awareness boost

# Built with

* [**D**](https://dlang.org)
* [`dub`](https://code.dlang.org)
* [`dlang-requests`](https://code.dlang.org/packages/requests)
* [`arsd`](https://github.com/adamdruppe/arsd)

## License

This project is licensed under the **MIT** license - see the [LICENSE](LICENSE) file for details.

## Acknowledgements

* [kameloso](https://www.youtube.com/watch?v=s-mOy8VUEBk) for obvious reasons
* [`README.md` template gist](https://gist.github.com/PurpleBooth/109311bb0361f32d87a2)
* [ikod](https://github.com/ikod) for [`dlang-requests`](https://github.com/ikod/dlang-requests) making the web-related plugins possible
* [Adam D. Ruppe](https://github.com/adamdruppe) for [`arsd`](https://github.com/adamdruppe/arsd), extending web functionality
* [`#d` on Freenode](irc://irc.freenode.org:6667/#d) for always answering questions
* [IRC Definition Files](http://defs.ircdocs.horse) and [`#ircdocs` on freenode](irc://irc.freenode.org:6667/#ircdocs) for their excellent resource pages

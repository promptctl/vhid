# vhid

A virtual keyboard and mouse for macOS, driven from the command line or by an AI agent.

[![test](https://github.com/promptctl/vhid/actions/workflows/test.yml/badge.svg)](https://github.com/promptctl/vhid/actions/workflows/test.yml)
[![release](https://img.shields.io/github/v/release/promptctl/vhid)](https://github.com/promptctl/vhid/releases/latest)
[![license](https://img.shields.io/github/license/promptctl/vhid)](LICENSE)

vhid creates two virtual input devices and types and clicks through them, so macOS
treats the input as coming from hardware. A script or an agent can then work where
software-generated input is blocked, such as the lock screen, the login window, and
password prompts, and it needs no Accessibility permission to do it. A companion tool,
`eyes`, reads the screen and prints where things are, as the coordinates `vhid click` takes.

```console
$ eyes find Save
1 matched "Save" in display 1 0,0 1600x900 by tree and pixels, merged; …
812,604	Save	AXButton

$ vhid click 812 604
clicked left once at (812, 604) after 4 motion reports

$ vhid type "quarterly-report"
typed 16 characters on com.apple.keylayout.US
```

Each line of output has the shape the command prints; the first line of `eyes find` is
longer than shown.

[promptctl.github.io/vhid](https://promptctl.github.io/vhid/) shows it working, filmed.

## Contents

- [Where the input reaches](#where-the-input-reaches)
- [Install](#install)
- [Use](#use)
- [Limits and status](#limits-and-status)
- [Documentation](#documentation)
- [Contributing](#contributing)
- [License and credits](#license-and-credits)

## Where the input reaches

Because the input comes from a device, it lands in places that synthetic events
can't reach. Measured over SSH on macOS 15:

| Where | Typing | Cursor and clicks |
|---|---|---|
| Logged in, SSH as the user in front | yes | yes |
| That user's lock screen | yes | yes |
| Terminal with Secure Keyboard Entry on | yes | yes |
| A system password prompt | yes | yes |
| The login window, nobody logged in | yes | yes |
| The login window after fast user switching | yes | yes |
| FileVault's unlock screen before boot | no | no |

[docs/design/remote-hands.md](docs/design/remote-hands.md) has the evidence for each cell.
On the 0.1.0 pkg the two login window rows take typing only; placing the cursor there
came in 0.2.0.

## Install

You need macOS 15 or later, on Apple silicon or Intel, and an administrator account.

With [Homebrew](https://brew.sh):

```sh
brew install --cask promptctl/tap/vhid
```

Or download the latest pkg from the [Releases page](https://github.com/promptctl/vhid/releases/latest)
and open it, or do the same from a terminal with the [GitHub CLI](https://cli.github.com):

```sh
gh release download --repo promptctl/vhid --pattern 'vhid-*.pkg'
sudo installer -pkg vhid-*.pkg -target /
```

The pkg is signed and notarized. It installs `vhid` and `eyes` in `/usr/local/bin`, a
background daemon that owns the two devices, a menu bar item that shows whether vhid is
ready, and the driver the devices are built on,
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice).
You don't need Karabiner-Elements. If you already have it, the pkg replaces the driver
files the two share.

One step is left to you, because macOS lets only the person at the Mac approve a driver:

1. Open **System Settings > General > Login Items & Extensions**.
2. Click the **(i)** beside **Driver Extensions**.
3. Turn on **org.pqrs.Karabiner-DriverKit-VirtualHIDDevice**.

Then check the install:

```console
$ vhid doctor
ready
Driver extension: running
launchd job: loaded, holding the service
Daemon: listening, both devices up
Signature: admitted
Devices: free
Keyboard Setup Assistant: answered ANSI for the virtual keyboard
```

If it prints `not ready`, the row that is wrong names the step to take.

To remove vhid, run `brew uninstall --cask vhid` if Homebrew installed it, and
`sudo /usr/local/libexec/vhid-uninstall` if you installed the pkg yourself.
[docs/installing.md](docs/installing.md) lists every file the pkg installs and covers
removing the driver too.

## Use

### Type and click

```sh
vhid type "hello"                            # type text wherever the keyboard is focused
vhid press leftCommand+s                     # press a key combination
vhid click 800 500                           # click at a screen point
vhid click 800 500 --button right --times 2
vhid move 800 500                            # move the pointer, pressing nothing
vhid scroll 800 500 --vertical 3             # roll the wheel at a point
vhid drag 100 100 400 300                    # press at one point, release at another
vhid cursor                                  # print where the pointer is
vhid record > script.jsonl                   # record your own keyboard and mouse (needs Input Monitoring); Control-C stops
vhid play < script.jsonl                     # replay a recording with its timing
```

Coordinates are screen points measured from the top left of the main display.
`vhid help <verb>` describes each verb, and [docs/cli.md](docs/cli.md) covers keyboard
layouts, negative coordinates on a second display, and the other rules the verbs share.

### Find things on screen

```sh
eyes find Save                # where "Save" is: the point to click, then the text
eyes read --window 4127       # every piece of text in one window, in reading order
eyes windows                  # each on-screen window: its id, owner and bounds
eyes displays                 # each display's id, bounds and scale
```

`find` and `read` can look in two ways. They read the accessibility tree, which is the
exact text that apps expose to assistive tools, and they recognise text in a capture of
the screen. The first needs the Accessibility permission and the second needs Screen
Recording, each granted to your terminal app under **System Settings > Privacy &
Security**. With only one granted, they answer from that one and say which was missing.
`windows` and `displays` need neither. [docs/eyes.md](docs/eyes.md) has the detail.

### From an AI agent

In Claude Code, install the vhid plugin once vhid itself is installed:

```
/plugin marketplace add promptctl/vhid
/plugin install vhid@vhid
```

The plugin adds both tools as [MCP](https://modelcontextprotocol.io) servers, MCP being
the protocol that AI clients such as Claude use to call external tools, and two skills:
one teaches the agent to look with `eyes`, act with `vhid`, and look again to see what
changed; the other invokes any app's menu item by its name, through the Help menu's
search. When vhid is missing or `vhid doctor` is not `ready`, each new session tells the
agent so, with the step to take.

[docs/mcp.md](docs/mcp.md) adds the two servers to Claude Code without the plugin or to
Claude Desktop, lists the tools, shows the loop step by step, and explains which app has
to hold the screen permissions.

## Limits and status

vhid is new software. What to know before relying on it:

- **vhid does not check what it is typing into.** It types wherever the keyboard is
  focused and clicks the point it is given, whatever is there. Looking first, with `eyes`
  or otherwise, is the caller's job.
- **It cannot reach FileVault's unlock screen.** Before the disk is unlocked, neither the
  daemon nor the driver is running.
- **Typing follows the caller's keyboard layout.** At the login window over SSH, that may
  not be the layout on screen, and `--layout` names the one to type on.
- **This page and `docs/` describe `master`, which is ahead of the latest release.**
  [CHANGELOG.md](CHANGELOG.md#unreleased) lists what the pkg does not have yet, above the
  notes for each release.
- **It installs a root daemon and a driver extension.** The daemon accepts commands only
  from a `vhid` signed with the same certificate it is.

## Documentation

| | |
|---|---|
| [docs/cli.md](docs/cli.md) | the `vhid` verbs, keyboard layouts, coordinates |
| [docs/eyes.md](docs/eyes.md) | reading the screen, waiting for text to appear or go, the events `eyes` logs |
| [docs/mcp.md](docs/mcp.md) | the MCP servers, client setup, permissions |
| [docs/installing.md](docs/installing.md) | what the pkg installs, `vhid doctor`, the menu bar item, uninstalling |
| [docs/development.md](docs/development.md) | repository layout, scope, building and testing |
| [docs/releasing.md](docs/releasing.md) | publishing a release |
| [docs/design/](docs/design) | design notes and the measurements behind them |

## Contributing

Report bugs and ask questions in [GitHub issues](https://github.com/promptctl/vhid/issues).
A bug report is most useful with the output of `vhid doctor` in it.

To build from source you need Xcode 26. CI builds with the version that
[test.yml](.github/workflows/test.yml) names, so that one is known to work:

```sh
git clone https://github.com/promptctl/vhid.git
cd vhid
make test                              # build, sign, and test vhid
(cd eyes && swift build && swift test) # eyes is a separate package with its own tests
```

Use `make` rather than `swift build` at the root. The daemon accepts only a `vhid`
signed with its own certificate, and `make` does that signing.
[docs/development.md](docs/development.md) explains this, how to run a development
daemon beside an installed one, and what belongs in the project. Pull requests go to
`master` and must pass the `vhid`, `eyes` and `pkg` checks.

## License and credits

vhid is licensed under the Apache License 2.0; see [LICENSE](LICENSE). [NOTICE](NOTICE)
lists the third-party software it links and carries.

The virtual devices are built on
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
by pqrs.org. vhid began as the typing layer of
[low-talker](https://github.com/promptctl/low-talker), a dictation tool, and is maintained
by [promptctl](https://github.com/promptctl).

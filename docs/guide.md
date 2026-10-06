# The vhid user guide

This guide is for someone who has been through the [README](../README.md)'s quickstart
and wants the rest: every way to install it, everything the two commands do, how to hand
them to an AI agent, and what to do when something fails. Sections point to the
reference page that has the full detail.

## What you installed

You now have two commands and a few things running behind them.

- **`vhid`** is the hands. It types, presses shortcuts, moves and clicks the pointer,
  scrolls, drags, and records and replays your own input.
- **`eyes`** is the eyes. It lists the windows and displays, and finds text on screen,
  printing the point to click.
- **A background service** (`vhidd`) owns the virtual keyboard and mouse. It runs as root,
  because the driver underneath takes commands only from root. `vhid` hands each key press to
  it, so you never run `sudo` yourself.
- **The driver** is [Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice),
  by pqrs.org. It makes the devices macOS sees. You don't need Karabiner-Elements.
- **A menu bar item** shows a keyboard when everything is ready and a warning triangle
  when it is not.

Every position either command prints or takes is a screen point measured from the top
left of the main display, so a point `eyes` finds is a point `vhid` can click, unchanged.

## Installing

There are three ways in, and all three install the same signed, notarized package, on
Apple silicon or Intel. With [Homebrew](https://brew.sh):

```sh
brew install --cask promptctl/tap/vhid
```

From a terminal without Homebrew, with the [GitHub CLI](https://cli.github.com):

```sh
gh release download --repo promptctl/vhid --pattern 'vhid-*.pkg'
sudo installer -pkg vhid-*.pkg -target /
```

Or download the `.pkg` from the [Releases page](https://github.com/promptctl/vhid/releases/latest)
and double-click it.

Then switch on the driver in **System Settings > General > Login Items & Extensions >
Driver Extensions (i)**. macOS won't let an installer take that step. Until it is
on, every command that types or clicks is refused with `devices not up:` and the step
to take; `vhid doctor` still works and says what is left. Once
it is, the devices come up within a few seconds, with no restart.

If you'd rather be walked through it, click the menu bar item and choose **Set Up vhid…**.
It shows each unmet requirement in turn, with why vhid needs it, and moves on by itself as
you fix each one.

To remove vhid:

```sh
brew uninstall --cask vhid                  # if Homebrew installed it
sudo /usr/local/libexec/vhid-uninstall      # if you installed the pkg yourself
```

Both leave the pqrs driver in place, since other software can share it.
`brew uninstall --zap --cask vhid` or `sudo /usr/local/libexec/vhid-uninstall --driver`
removes the driver too.

[installing.md](installing.md) lists every file the package installs and covers the
uninstall cases in full.

## Typing and pressing keys

```sh
vhid type "hello"                       # type text wherever the keyboard is focused
vhid type --into TextEdit "hello"       # ...but only if TextEdit is the app in front
vhid press leftCommand+s                # a shortcut
vhid press leftCommand+a delete         # several, one after another
vhid gesture mission-control            # what a trackpad gesture does, by its keyboard shortcut
```

`vhid` types with your keyboard layout. When the layout on screen is a different one, as
it can be at the login window when you are typing over SSH, name it with
`--layout com.apple.keylayout.Dvorak`. Text the layout has no keys for is refused whole,
before any key goes down, so you never get half a sentence.

`--into <app>` checks once, just before the first key, which app is in front, and sends
nothing if it is the wrong one. It checks the app, not the field, so a dialog from another
process that sits over the app still takes the keys.

`gesture` exists because the virtual devices are a keyboard and a mouse, not a trackpad.
macOS will not accept a virtual trackpad without an entitlement from Apple. So each
gesture is done by the shortcut or click that has the same effect. `vhid help gesture`
lists them.

## Moving, clicking and scrolling

```sh
vhid cursor                             # where the pointer is now
vhid move 800 500                       # move it, pressing nothing
vhid click 800 500                      # left-click there
vhid click 800 500 --button right --times 2
vhid click 800 500 --modifiers leftCommand
vhid click 760,488,80,24                # click inside the box eyes printed, as a hand lands on a button
vhid scroll 800 500 --vertical 3        # roll the wheel over that point
vhid drag 100 100 400 300               # press at one point, release at the other
```

A display to the left of or above the main one has negative coordinates. Put them after
`--` so they aren't read as options: `vhid click -- -100 40`. `eyes displays` shows where
each display sits.

[cli.md](cli.md) has every verb and option. `vhid help <verb>` has the same text at your
terminal.

## Recording and replaying

```sh
vhid record > session.jsonl             # record your keyboard and mouse; Control-C stops
vhid play < session.jsonl               # play it back, with the same timing
```

A recording is a plain text file, one action per line, so you can read it, edit it, or
write one by hand. `vhid help play` describes the format. Recording needs the Input
Monitoring permission, which macOS asks for the first time you run it. Playing back needs
nothing. [design/replay.md](design/replay.md) explains how the format was chosen.

## Reading the screen with eyes

```sh
eyes windows                            # every window: its id, its app, where it is
eyes displays                           # every display: its id, where it is, its scale
eyes find Save                          # where "Save" is on screen: the point, its box, then the text
eyes find Remove --near Beta            # several "Remove" buttons: the one beside "Beta" first
eyes read --window 4127                 # all the text in one window, in reading order
eyes find Saving --until absent --timeout 30   # wait until "Saving" has gone
```

`eyes` reads the screen two ways and merges them. It asks the accessibility tree, the
text apps publish for screen readers, which is exact and says what each thing is: a
button, a link, a field. It also recognises text in an image of the screen, which catches
anything drawn, such as words on a canvas. The first way needs the **Accessibility**
permission and the second needs **Screen Recording**. Each is granted to the app you run
`eyes` from, such as Terminal or iTerm. `eyes grants` says which you hold, and
`eyes grants --ask` raises macOS's request for the rest. With only one granted, `eyes`
answers from that one and says which was missing.

In a browser, `--page <window id>` reads only the web page, not the toolbar and
bookmarks, so a bookmark named "Settings" isn't mistaken for the page's Settings button.

[eyes.md](eyes.md) covers every option.

## Handing it to an AI agent

Both commands also run as [MCP](https://modelcontextprotocol.io) servers, the standard
way AI apps call outside tools. In Claude Code the plugin sets everything up:

```
/plugin marketplace add promptctl/vhid
/plugin install vhid@vhid
```

The plugin adds both servers and two skills. One teaches the agent to work in a loop: look
with `eyes`, act with `vhid`, then look again to see whether the act worked. The other
reaches any app's menu items by name, through the Help menu's search. At the start of
each session the plugin also checks `vhid doctor` and tells the agent what is missing, if
anything is.

The agent's `eyes` permissions belong to whichever app it runs in, such as your terminal
app for Claude Code, or Claude itself for Claude Desktop.
[mcp.md](mcp.md) shows how to add the servers to Claude Desktop or to Claude Code
without the plugin, and lists every tool.

## Where the input reaches

Because the input comes from a device, it gets through where faked input doesn't. Each
row was measured on a Mac running macOS 15, with `vhid` run over SSH:

| Where | Typing | Pointer and clicks |
|---|---|---|
| Logged in, SSH as the user at the Mac | yes | yes |
| That user's lock screen | yes | yes |
| Terminal with Secure Keyboard Entry on | yes | yes |
| A system password prompt | yes | yes |
| The login window, nobody logged in | yes | yes |
| The login window after fast user switching | yes | yes |
| FileVault's unlock screen, before macOS starts | no | no |

[design/remote-hands.md](design/remote-hands.md) has how each cell was shown.

## What vhid won't do for you

- **It doesn't look before it acts.** `vhid` types wherever the keyboard is focused and
  clicks whatever is at the point it is given. `--into` checks the app in front and
  nothing finer. Look first, with `eyes` or with your own eyes.
- **It can't reach FileVault's unlock screen.** Before the disk is unlocked, neither the
  service nor the driver is running.
- **It serves one caller at a time.** While one `vhid` command is typing, a second is
  refused, with the process id of the one holding the devices, so two never type into
  each other. Run it again once the first has finished.
- **These docs describe the latest code, which may be ahead of the latest release.**
  [CHANGELOG.md](../CHANGELOG.md#unreleased) lists what the released package doesn't have
  yet.

## When something goes wrong

Start with `vhid doctor`. It prints `ready` or `not ready`, then one line for each thing
vhid needs: the driver, the background service, whether the service accepts this `vhid`,
whether another program is holding the devices, and the keyboard type macOS asked about
when the virtual keyboard first appeared. Any line with a problem names the step that
fixes it. The menu bar item shows the same lines, and clicking one copies it.

In releases after 0.4.1, every `vhid` command, and every tool call an agent makes, appends one line to
`~/Library/Logs/vhid/events.jsonl`: which command it was, whether it worked, how long it
took and how many key and pointer reports it sent. `eyes` keeps its own in
`~/Library/Logs/eyes/events.jsonl`. Neither records the text you typed. If you run an
[OpenTelemetry](https://opentelemetry.io) collector, set `OTEL_EXPORTER_OTLP_ENDPOINT`
and the records go there instead. [cli.md](cli.md#what-each-run-leaves-behind) describes
the fields.

A bug report is most useful with the output of `vhid doctor` in it.
[Open an issue](https://github.com/promptctl/vhid/issues).

## Reference

| Page | What it covers |
|---|---|
| [cli.md](cli.md) | every `vhid` command, keyboard layouts, coordinates, the event log |
| [eyes.md](eyes.md) | every `eyes` command, waiting for text, browser pages |
| [mcp.md](mcp.md) | the MCP servers, setting up AI apps, whose permissions count |
| [installing.md](installing.md) | every installed file, `vhid doctor`, the menu bar item, uninstalling |
| [security.md](security.md) | what runs as root, who may call it, what is logged |
| [architecture.md](architecture.md) | how it works inside, for building and changing it |

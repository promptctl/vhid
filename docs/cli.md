# The vhid command line

The verbs that type, click and replay, and the rules they share: keyboard layouts, coordinates, and which daemon a `vhid` talks to. `vhid help` lists every verb, and `vhid help <verb>` has each one's full text.

```sh
vhid type "hello"
vhid type --into TextEdit "hello"
vhid press leftCommand+s
vhid gesture mission-control
vhid click 800 500 --button left --times 2
vhid click 800 500 --modifiers leftCommand+leftShift
vhid move 800 500
vhid scroll 800 500 --vertical 3
vhid drag 100 100 400 300
vhid cursor
vhid play < script.jsonl
vhid record > script.jsonl   # Control-C stops; needs Input Monitoring for vhid-record.app (a working tree builds ~/Applications/vhid-record-dev.app)
vhid doctor
```

It types where the keyboard is pointed and clicks where it is told. There is no
click-by-element, because nothing in vhid reads the screen — what is under a point is
the caller's to know.

`type` and `press` take `--into <app>` (the MCP tools, `into`): the app the keys are
for, named as `eyes windows` prints the frontmost application on its first line. Just before the first key, the
verb asks macOS which app is in front and, when it is another, refuses with nothing
sent, naming the app that was: `TextEdit is not in front, so nothing was sent: Terminal
(pid 512) is`. It is asked once, so a window that comes forward while the keys are going
down still gets the rest, and it is the app that is checked, not the field or a panel of
another process over it.

Which keys make which characters is the calling user's keyboard layout, read in the CLI
rather than in the daemon: macOS answers that question per process, and a root daemon
asking it is told the US layout whatever the user is typing on. `type`, `press` and
`gesture` take `--layout <input source id>` (the MCP tools, `layout`) to name another, as
at the login window over SSH, where the caller's layout need not be the one on screen.
`type` refuses text the layout has no keys for.

`gesture` does what a trackpad gesture does, by pressing the key that does the same
thing: `back` is ⌘[, `mission-control` is Mission Control's shortcut. A system shortcut
is the calling user's, as System Settings > Keyboard > Keyboard Shortcuts has it at the
moment of the call, and so is look-up's ⌃⌘D, which System Settings does not list; one
that is off is refused, naming the setting, and so is a gesture no key does, such as
`smart-zoom`. `vhid help gesture` lists every gesture and its key, and
[design/gestures.md](design/gestures.md) has the measurements behind them.

`--service` says which installation to talk to. It defaults to the one the binary was
built for: the installed copy for the installed CLI, and the development copy for a
build from this tree. `vhid service` prints which. Coordinates are screen points from the top left of the main display; a display
left of or above it has negative ones, which follow `--` after every option:
`vhid click --button left -- -100 -40`.

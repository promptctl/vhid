# The vhid command line

The verbs that type, click and replay, and the rules they share: keyboard layouts, coordinates, and which daemon a `vhid` talks to. `vhid help` lists every verb, and `vhid help <verb>` has each one's full text.

```sh
vhid type "hello"
vhid press leftCommand+s
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
click-by-element and no target app, because nothing in vhid reads the screen — what is
under a point is the caller's to know.

Which keys make which characters is the calling user's keyboard layout, read in the CLI
rather than in the daemon: macOS answers that question per process, and a root daemon
asking it is told the US layout whatever the user is typing on. `type` and `press` take
`--layout <input source id>` (the MCP tools, `layout`) to name another, as at the login
window over SSH, where the caller's layout need not be the one on screen. `type` refuses
text the layout has no keys for.

`--service` says which installation to talk to. It defaults to the one the binary was
built for: the installed copy for the installed CLI, and the development copy for a
build from this tree. `vhid service` prints which. Coordinates are screen points from the top left of the main display; a display
left of or above it has negative ones, which follow `--` after every option:
`vhid click --button left -- -100 -40`.

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
another process over it. At the login window, or with another user's session in front,
the app in front cannot be read from this user's session, so `--into` refuses there too.

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

## What each run leaves behind

Every `vhid` run, and every MCP tool call, leaves one record: a line of JSON appended to
`~/Library/Logs/vhid/events.jsonl`. A run that sent nothing and a run that never happened
look different there, because a run that opened the devices counts its reports from
zero; whether the daemon answered is in its `outcome` and `error`. Control-C or
`SIGTERM` stops a verb as a withdrawn MCP call is stopped: it is recorded as `cancelled`
with what it had sent and `attributes.signal` naming the signal, says so on stderr, and
then dies by the signal; `doctor`, `driver` and `service` end the command they are
running to read this Mac and start none after it, and `attributes.stopped` lists the
commands ended, empty when none was running. `doctor` still waits out the daemon's status
reply, which gives up after five seconds. `vhid record` answers
the first one by finishing, and exits as the recording ended. A second signal ends any
verb at once, unrecorded, and an MCP call `vhid mcp` was running when it was stopped
names the signal too.

```json
{"attributes":{"double_click_ms":500,"paths":[{"bow_kept":1,"closing_reports":1,"displays":[[0,0,1512,982]],"lost_reports":0,"planned_ms":612.4,"steered_reports":71}],"pauses":{"notch":{"count":3,"ms":691.4},"rest":{"count":1,"ms":262.7}},"seed":"9e3779b97f4a7c15"},"counts":{"keyboard_reports":0,"mouse_reports":75,"scroll_notches_horizontal":0,"scroll_notches_vertical":3},"duration_ms":1601.3,"entry":"cli","event":"scroll","outcome":"ok","service":"vhid","sink":"file","started_at":"2026-10-04T13:20:00.512Z","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

`event` is the verb as it is typed (`scroll`, `driver state`), and an MCP call's is its
tool's name, which is the same word; `entry` says which it came through. `outcome` is
`ok`, `failed` or `cancelled`, and `error` is what the caller was told, absent when a verb
said its piece and exited nonzero, as `doctor` does. Refused arguments are recorded as
refused but not quoted, since they can hold text meant for a password field, and for the
same reason a `type` run's error names its kinds (`TypingStopped: UntypeableCharacters`)
rather than quoting its words. An argument that could not be parsed
is recorded as `vhid`, before the verb was known, and `--help` as `help`; an MCP call
naming no tool is recorded as `tools/call`. An MCP call's
`attributes.queued_ms` is how long it waited behind the calls before it, which its
`duration_ms` includes.

A verb that opens the devices records `attributes.seed`, the hex seed every pointer move
it makes is drawn from, and `attributes.paths` has one entry for each such move, in order,
the move a failed verb stopped in included: `planned_ms` is how long its trajectory was
drawn to take, `displays` the display layout it was kept on, each display as its left,
top, width and height, `bow_kept` how much of its drawn curve it kept to stay clear of the
displays' edges (1 for all of it, 0 for a straight line), `steered_reports` how many
reports carried the cursor along it,
`lost_reports` how many of those the cursor never showed, and `closing_reports` how many
the closed loop took to land it after. `click`, `move` and `scroll` make one move and
`drag` two. `attributes.pauses` totals the pauses the pointer made between reports by kind, the
one a stopped verb was in included, each kind with its `count` and the `ms` they slept: a
`rest` on the point before a press, a drag's release or a scroll's first notch, a click's
`hold`, the `gap` between the clicks of a double click, a drag's `drag_hold` before it
carries the button, and a `notch` pause after each notch. Each is drawn from the seed
too. `attributes.double_click_ms` is the double-click interval the click timings were
fitted to, as this process read it.

With `OTEL_EXPORTER_OTLP_ENDPOINT` set, the record goes to that OpenTelemetry collector
instead, as an OTLP/HTTP JSON log on `/v1/logs`, and the file is not written.
`OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` names the logs URL itself and wins over it, and
`OTEL_EXPORTER_OTLP_HEADERS` (or `_LOGS_HEADERS`) are sent with every record, as the
OpenTelemetry specification defines them. `OTEL_SDK_DISABLED=true` or
`OTEL_LOGS_EXPORTER=none` keeps records in the file, and a `grpc`
`OTEL_EXPORTER_OTLP_PROTOCOL` is refused on each record, since vhid sends OTLP/HTTP JSON.
An MCP call is answered before its record is sent, and `vhid mcp` waits for every record
before it exits. A collector
that refuses it, or has not answered in two seconds, leaves it in the file with
`sink_error` saying why.

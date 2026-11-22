# The vhid command line

The verbs that look, type, click and replay, and the rules they share: keyboard layouts, coordinates, and which daemon a `vhid` talks to. `vhid help` lists every verb, and `vhid help <verb>` has each one's full text.

```sh
vhid look                    # the displays, the windows front to back, and the text in front
vhid look --text Save        # where "Save" is: the point to click, its box, then the text
vhid look --text Saving --window 4127 --until absent --timeout 30
vhid look --app Safari       # Safari's windows and what is stacked in front of them
vhid look --x 169 --y 426    # what a click at 169,426 lands on: the app, its window, the element
vhid type "hello"
vhid type --into TextEdit "hello"
vhid press leftCommand+s
vhid gesture mission-control
vhid click 800 500 --button left --times 2
vhid click 800 500 --modifiers leftCommand+leftShift
vhid click 760,488,80,24     # inside the box look printed: x,y,width,height
vhid move 800 500
vhid scroll 800 500 --vertical 3
vhid drag 100 100 400 300
vhid cursor
vhid play < script.jsonl
vhid record > script.jsonl   # Control-C stops; needs Input Monitoring for vhid-record.app (a working tree builds ~/Applications/vhid-record-dev.app)
vhid doctor
```

It types where the keyboard is pointed and clicks where it is told. There is no
click-by-element: `look` says what is on screen, and which point to press is the
caller's to choose.

`look` reads the screen, its options the `look` tool's arguments. With no `--text` it prints
three blocks, a blank line between them: the displays, main first, each its id, main or
secondary, bounds and scale; the windows front to back, each its id, owner, layer and
bounds, the frontmost application's rows marked `front`; and the text read in the place,
a scope line then a row per run, or `No text was read:` and why, with the first two still
printed. With `--text` it prints the scope line and the rows that match, or the nearest
runs and how many edits off each is; `--exact` matches only a run that is the text, and
`--edits` sets how many edits off a run may be, not both. `--near` orders the matches by
closeness to a run holding that text, and `--until present|absent` with `--timeout`
(at most 600 seconds, 10 when left out) reads again until the text comes or goes. The
place is at most one of `--display`, `--window`, `--page`, `--rect` and `--app`, and with
none it is what is in front. `--limit` (50 when left out), `--source tree|pixels|merged`
and `--role` narrow the rows. `--x` and `--y`, given together and with nothing else, say
what a click at that point would land on. An option that does not fit is refused by name:
`give at most one of display, window, page, rect, app`. [eyes.md](eyes.md) has how the
place is read, what each row and scope line says, and the waits. A look asks nothing of
the daemon, so it waits behind no device call. The tree needs Accessibility and pixels
Screen Recording, granted to the app responsible for the process; `doctor` ends with
whether each is held and names that app.

`type` and `press` take `--into <app>` (the MCP tools, `into`): the app the keys are
for, named as `look` prints the frontmost application in its windows block. Just before the first key, the
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

`click`, `move`, `scroll` and `drag` take each place as a point, two numbers `x y` or one
word `x,y`, or as a box, one word `x,y,width,height`: the point and the box `look` prints
for each run. The displays are read once when the verb starts, sleeping ones included, and
each place is pressed by one rule. A point is pressed where it is. A box is pressed in the
largest part of it one display shows, at least a point a side, where the pointer lands on
a point drawn inside that part, spread about the centre as a person's clicks spread on a
button and never within 2 points of its edge (a side too narrow for that is aimed at its
centre), and the move there takes as long as Fitts' law says a hand's would to a target
that size. A point or a box no display shows is refused, saying it is on no display and
listing the displays. The MCP tools take `box` in place of `x` and `y`, and `drag`'s
`from` and `to` take a point or a box as a string.
[design/human.md](design/human.md#where-a-click-lands) has the model.

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
{"attributes":{"double_click_ms":500,"paths":[{"aimed":[812.4,503.1],"bow_kept":1,"bow":0.031,"box":[772,491,80,24],"closing_reports":1,"displays":[[0,0,1512,982]],"ends_kept":1,"fitts_width":24,"from":[640,512],"halfway":0.437,"landed":[812.4,503.1],"lost_reports":0,"planned_ms":612.4,"steered_reports":71,"structure":"undershoot"}],"pauses":{"notch":{"count":3,"ms":691.4},"rest":{"count":1,"ms":262.7}},"entry":"cli","seed":"9e3779b97f4a7c15"},"counts":{"keyboard_reports":0,"mouse_reports":75,"scroll_notches_horizontal":0,"scroll_notches_vertical":3},"duration_ms":1601.3,"event":"scroll","outcome":"ok","service":"vhid","sink":"file","span_id":"00f067aa0ba902b7","started_at":"2026-10-04T13:20:00.512Z","trace_id":"4bf92f3577b34da6a3ce929d0e0e4736"}
```

`event` is the verb as it is typed (`scroll`, `driver state`), and an MCP call's is its
tool's name, which is the same word; `entry` says which it came through. `outcome` is
`ok`, `failed` or `cancelled`, and `error` is what the caller was told, absent when a verb
said its piece and exited nonzero. A verdict is not a failure: `doctor` on a Mac that is not
ready, and `read-grants` reading a grant not held, record `ok` and exit with the status their
verdict is. Refused arguments are recorded as
refused but not quoted, since they can hold text meant for a password field, and for the
same reason a `type` run's error names its kinds (`TypingStopped: UntypeableCharacters`)
rather than quoting its words. An argument that could not be parsed
is recorded as `vhid`, before the verb was known, and `--help` as `help`; an MCP call
naming no tool is recorded as `tools/call`. An MCP call's
`counts.queued_ms` is how long it waited behind the calls before it, which its
`duration_ms` includes.

A verb that opens the devices records `attributes.seed`, the hex seed every pointer move
it makes and every key it times is drawn from, and `attributes.paths` has one entry for each such move, in order,
the move a failed verb stopped in included: `from` is where the cursor was when it began,
`aimed` the point it aimed at, `x` and `y`, drawn inside the box from there when it was
given one, `box` the part of it a display shows, which the point was drawn inside, as
`x,y,width,height`, and `bound` the box as given (both absent
for a point), `fitts_width` the target width its time was
read from (the part's smaller side, or 20 for a point), `landed` where the cursor was read
when it landed, absent for a move that stopped first, `planned_ms` is how long its trajectory was
drawn to take, `structure` how it was built (`direct`, `undershoot`, `overshoot` or
`two_corrections`), `bow` its drawn curve as a fraction of the distance, away from the
elbow when positive and toward it when negative, `halfway` the share of each movement's
time by which it had covered half its distance, `displays` the display layout it was kept on, each display as its left,
top, width and height, `ends_kept` and `bow_kept` how much of where its movements end off
the straight line and of its drawn curve it kept to stay clear of the displays' edges (1
for all of it, 0 for none; both 0 is the straight line), `steered_reports` how many
reports carried the cursor along it,
`lost_reports` how many of those the cursor never showed, and `closing_reports` how many
the closed loop took to land it after. `click`, `move` and `scroll` make one move and
`drag` two. `attributes.pauses` totals the pauses made between reports by kind, the
one a stopped verb was in included, each kind with its `count` and the `ms` they slept. The
pointer's are a
`rest` on the point before a press, a drag's release or a scroll's first notch, a click's
`hold`, the `gap` between the clicks of a double click, a drag's `drag_hold` before it
carries the button, and a `notch` pause after each notch. `type`'s and `press`'s are named
for the report each wait ends in: `modifier_down`, `key_down`, `key_up` (a key's hold) and
`modifier_up`. Each is drawn from the seed too. `counts.key_rollovers` is how many keys went
down while another was held, and `counts.key_hesitations` how many words a hesitation came
before; `attributes.key_hesitation_ms` totals the hesitations' drawn lengths, which the
waits they precede already include. Both counts are 0 for a verb that opened the devices
and typed nothing, and `key_hesitation_ms` is absent for a verb that never typed. `attributes.double_click_ms` is the
double-click interval the click timings were fitted to, and `attributes.key_repeat_delay_ms`
the delay until a held key repeats that key holds were fitted to, both as the HID system
holds them for the session in front. `attributes.keys_late_ms` is how far behind
its drawn timing `type`'s or `press`'s last report went out: slow acknowledgements and late
wakes move every key after them rather than shorten a hold. It is 0 for a run that sent
no keys, and absent for a verb that never typed.

A finished `play` records `attributes.layout`, as its done line says it: `kept` when the
displays, read again once its last report was out, have the same frames in the same order
as the ones the script was placed on, whichever are asleep, `changed` when they do not, and
`unread` when they could not be read, with `attributes.layout_unread` saying why. `vhid record` records `attributes.ending`, how the
recording ended (`stop` for Control-C, `end` for `SIGTERM`, `tap_off` when macOS turned
the tap off, `hour`, `devices_lost` when vhid's devices came back and could not be told
apart again, or `layout_lost` when the displays changed and could not be read), and
`attributes.left_out`, what it left out by reason, zeros included: `unmapped_keys`, key
presses with no HID usage, fn among them; `off_display`, the moves to a point no display
holds; `unlocated`, the events the tap gave at a point that is not a place on the screen;
and `layout_changes`, how many times the displays came to be laid out otherwise.

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

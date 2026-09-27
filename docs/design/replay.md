# Replay and record: design

`vhid play` replays one timed script that drives both devices, and `vhid record` writes that script from a person's hands. This document settles the script format, where recording reads input from, and the questions that sit between them. Where a question was empirical, the answer comes from a measurement on a MacBook with a Bluetooth Magic Trackpad and the internal keyboard (macOS 26.3, pqrs driver 1.8.0), and each measurement is described well enough to repeat.

## The decisions

- **A script states what is held, not what changed.** Keyboard lines carry the whole set of keys down; button lines carry the whole set of buttons down. Replay builds every report from a held set, as the devices already do.
- **One clock.** Every line has a `t_ms` on the same clock, whichever device it drives.
- **Recording reads the session event tap, not raw HID.** The trackpad never reaches raw HID, so a HID recorder would record no pointer at all on this Mac.
- **Recorded pointer motion is absolute.** Tap deltas are already accelerated, so motion is recorded as points and replayed by steering toward them. Hand-written scripts keep raw `move` counts.
- **vhid's own events are dropped by their sender.** Every event vhid's virtual devices produce carries the driver's registry ID in event field 87; the trackpad's events carry no such value.
- **The helper protocol gains one call, `hold(usages:)`.** It sets the keyboard to exactly that set of keys. A repeated non-empty set is a keep-alive that posts no report; an empty set always posts.

## The script format

The format stays JSON Lines, parsed whole or refused whole, as `Play.parse` does today (`Sources/Input/Play.swift`). The first line is still where the cursor starts. Every line after it carries `t_ms` and exactly one of:

| Line | Meaning |
| --- | --- |
| `{"t_ms":0,"keys":["leftShift","keyboardA"]}` | these keys, and no others, are down from now |
| `{"t_ms":0,"buttons":["left"]}` | these buttons, and no others, are down from now |
| `{"t_ms":8,"move":{"dx":4,"dy":0}}` | raw counts, unchanged from today |
| `{"t_ms":8,"at":{"x":812.5,"y":400}}` | the cursor should be here now |
| `{"t_ms":16,"wheel":{"v":-1,"h":0}}` | wheel ticks, unchanged from today |

A key is named by its HID usage, the physical key, never by the character a layout puts on it: a name from the keyboard page (`keyboardA`, `leftShift`) or its number. The characters `vhid press` reads are resolved through the current layout and, when Command is held, through the Command layer (`Sources/Input/ChordSpelling.swift`). A held set spelled that way could name different keys on two lines of one script, and a different key again on another layout.

`buttons` takes the words and numbers a `down` line takes today, and it replaces `down` and `up`. Buttons become a held set for the same reason keys do: a recording of two buttons where one is released first cannot be written as "every button up". That breaks every existing `vhid pointer play` script, and it is meant to: `vhid play` replaces that command, and nothing has been released yet.

A script moves the pointer with `move` lines or with `at` lines, never both. `move` is for hand-written scripts that must feed acceleration identical counts on every run; `at` is what the recorder writes.

**Held sets rather than events**, because the device only ever sends held sets. A line that says "A up" means nothing unless the reader tracks everything that came before it, while a line that says `["leftShift"]` is true on its own. The parser can then check the whole script without tracking any state beyond the previous line.

**One clock**, because the point of a recording is the order and spacing of acts across both hands. Shift held through a click is a keyboard line, a button line, and a keyboard line on one timeline; two clocks would have to be merged back into one to play them.

**Refusals at parse time**, added to the ones `Play` already makes:

- A script must end with `"keys":[]` and `"buttons":[]` in force, the same guarantee `Play` gives for buttons today, now covering keys.
- A `keys` line naming more than 32 non-modifier keys is refused, because one report of the virtual keyboard carries 32 (`KeyboardReport.capacity`, `Sources/VirtualHID/VirtualKeyboard.swift`) and the device would refuse it mid-replay.
- A script with both `move` and `at` lines is refused.
- A name that is no key, or a key named twice, is refused by name.

### Holding a key longer than two seconds

vhidd releases any key that has been down for two seconds with no report from the client (`Devices.keyLimit`, `Sources/vhidd/Devices.swift`). A recording that holds Shift for three seconds with nothing else happening would be cut.

The player answers this, not the format: while a key is held, it calls `hold(usages:)` again with the current set whenever a second has passed since its last call to either device. The daemon marks the client alive on every call, before the act runs (`Devices.attempt` sets `lastReport`), so the repeat keeps the key down. The repeat does not reach macOS as a new key press, because the keyboard skips posting a non-empty set equal to the one it holds. That skip lives in the daemon's `VirtualKeyboard`, under the device lock and after the call has marked the client alive; a client that skipped the call instead would lose its keys at two seconds. A stopped player still loses its keys after two seconds, which is what the limit exists for.

## Replaying `at` lines

An `at` line gives a position, and the device only speaks counts. When a line comes due, the player reads the cursor (a `CGEvent` location read, which does not wait) and sends a report from where the cursor actually is toward the line's point, sized with a gain it learns from each report's observed motion, the way `Pointer.move(to:)` learns `Pointer.Gain` within one move (`Sources/Input/Pointer.swift`). The player keeps that gain across the whole script rather than restarting from `Gain.assumed` on every line. Because each report is aimed from the real cursor, an error on one line is corrected on the next rather than added to it. A step longer than a report can carry, 127 counts, is split over several reports within the line's interval. The player does not wait for the cursor to settle between lines, so the clock keeps its pace.

Before any `buttons` line and at the end of the script, the player runs the pointer's closed loop (`Pointer.move(to:)`) until the cursor is at the last `at` point. Scripts that use `move` lines never run the loop. Every click and every drag release therefore lands where it was recorded, which is what the epic's done criterion checks. The loop takes time, so it pushes every later line back by however long it took. Recorded timing is preserved between clicks, not across them.

Recording raw counts would replay more faithfully between clicks, but only for a device that reaches raw HID, and the trackpad does not (measured below).

## Where recording reads from

**The session event tap, listen-only, for keys, buttons and motion.**

Measured: HIDProbe, a signed app bundle with Input Monitoring granted (confirmed as `auth_value` 2 in `/Library/Application Support/com.apple.TCC/TCC.db`, with Karabiner not running), opened an `IOHIDManager` matching every generic-desktop mouse and pointer, plus a listen-only tap. For 15 seconds a person moved and clicked the Magic Trackpad. The tap received 528 motion events and 3 clicks; `IOHIDManager` received no values at all from the trackpad, neither motion nor buttons. The trackpad's pointer is made in software from touches, so raw HID cannot record it.

Measured: a script of ten 3-count reports, then ten 40-count reports, played through the virtual mouse. `IOHIDManager` saw exactly 3 and 40. The tap saw about 1.12 points per 3-count report (reported as a whole-number delta of 1 or 2) and 73.3 points per 40-count report. So a tap delta is accelerated and rounded, and replaying it as counts would put the cursor somewhere else. That is why tap motion is recorded as the tap's `location`, a point, and replayed through `at`.

Keys come from the tap's `keyDown`, `keyUp` and `flagsChanged` events. `Usage(virtualKeyCode:)` (`Sources/Keystrokes/VirtualKeyCode.swift`) turns their key codes into the usages a `keys` line names. The recorder writes a `keys` line each time the held set changes, and drops events the tap marks as autorepeat (`keyboardEventAutorepeat`), since macOS makes those from a held key and replay makes them again.

Three kinds of key need rules of their own:

- **Modifiers.** A `flagsChanged` event names the key that changed in its key code (left Shift 56, right Shift 60), so the recorder toggles that one usage. It does not read the shared Shift flag, which cannot tell the two Shifts apart.
- **Caps Lock** sends `flagsChanged` when it toggles and never a release. The recorder writes it as a press: the set with Caps Lock, then the set without it on the next line.
- **A key with no usage**, fn above all, is left out of the recording, and `vhid record` says on stderr how many such presses it left out.

## Keeping vhid out of its own recording

Measured: every event from vhid's virtual devices carries a non-zero value in tap field 87. Motion from the virtual pointer carried 4297410007, and an F16 pressed by `vhid press f16` carried 4297409985. Motion from the trackpad carried no field 87 at all. Both values appear in the `IOAssociatedServices` of the pqrs driver's services in `ioreg`.

The recorder therefore drops any event whose field 87 is the registry ID of one of the pqrs virtual device services. It resolves those IDs from the I/O Registry when recording starts, and again whenever an I/O Kit notification says a pqrs service appeared, since vhidd or the driver restarting mid-recording re-creates the devices under new IDs. Replay while recording then records the person and not the replay. Field 87 is not a published `CGEventField` constant, so `vhid record` has to refuse to start when it cannot resolve those registry IDs, rather than record everything.

Karabiner-Elements posts through the same pqrs driver. With its grabber running, a person's own typing would reach the tap from a pqrs service and be dropped as vhid's. So `vhid record` refuses to start while `karabiner_grabber` is running. That Karabiner's output carries a pqrs field 87 follows from the driver being shared; it was not measured.

## The grant recording needs

A listen-only tap that sees key events needs Input Monitoring (`kTCCServiceListenEvent`), and macOS gives that grant to the responsible process, not to the binary that asks. A signed app bundle gets its own entry: HIDProbe, launched with `open`, was listed under its bundle ID, granted once, and recorded as described above.

So `vhid record` runs its tap in a small signed app bundle shipped in the pkg next to `vhid`. The `vhid record` command launches it with `open`, which goes through LaunchServices, so the app is not its child: it inherits no pipe and gets none of the command's signals. The two are tied together explicitly:

- `vhid record` makes a Unix socket in a directory only its user can read, and passes the socket's path and its own pid to the app as arguments.
- The app sends every line over that socket, and exits when the socket closes or when a process source (`DispatchSource.makeProcessSource`, `.exit`) says that pid has ended. A `vhid record` killed with SIGKILL therefore leaves no tap running.
- A stop is a message on the socket: `vhid record` turns its own SIGINT into one. The person grants Input Monitoring once, to that bundle, whatever launched `vhid`: a terminal, tmux, or an MCP host. That removes the question of whom TCC blames for an MCP host, because the host is never the responsible process.

## Stopping without recording the stop

A recording made from a terminal ends with Control-C, and the tap sees Control and C go down before the shell's SIGINT reaches `vhid record`.

On SIGINT, `vhid record` tells the app to stop, and the app:

1. keeps reading for up to half a second, or until no key is held, so the stop chord's own events have arrived whichever order they came in;
2. drops the trailing `keys` lines back to the last line whose set was empty, if every key they hold is Control or C; any other key in that run is kept, because it was not the stop;
3. writes a final `"keys":[]` and `"buttons":[]` at the stop time, so the script ends with nothing held, as the parser requires.

Pointer lines in that window are kept; they are the person's. A recording ended any other way (SIGTERM, a duration limit) drops nothing.

## The helper boundary

`DeviceService` (`Sources/Helper/HelperService.swift`) gains one call:

```swift
/// Holds exactly `usages` down, which may be none, and answers when the daemon has
/// acknowledged the report. A non-empty set equal to what is already held posts
/// nothing and counts only as the client being alive; an empty set always posts, as
/// `releaseAll` does.
func hold(usages: [UInt16], reply: @escaping (Error?) -> Void)
```

It keeps every guarantee the daemon gives today:

- The keyboard still derives every report from its own held set; `hold` replaces the set, as `down` adds to it and `releaseAll` empties it. The device stays the one record of what is down.
- A client that disconnects or crashes is released by `releaseEverything` as before, because that releases whatever the device holds, however it came to be held.
- The key deadline still applies, and a player that stops sending loses its keys after two seconds.
- More than 32 non-modifier usages is refused by name (`TooManyKeys`) rather than truncated.

`down` and `releaseAll` stay, since typing and chords use them. `hold([])` posts unconditionally, as `releaseAll` does, because a final all-up report is the line between a run that ends and a key macOS goes on repeating (`VirtualKeyboard.releaseAll`). So the player uses `hold` throughout and still ends every script with that report.

## Repeating the measurements

The probes were throwaway Swift files; each is a few lines around one API:

- **Counts against deltas:** an `IOHIDManager` input-value callback on generic-desktop usages 0x30/0x31, next to a listen-only `CGEvent.tapCreate` on `mouseMoved` printing `mouseEventDeltaX` and `location`, while `vhid pointer play` sends known counts.
- **Trackpad on HID:** the same, filtered to devices other than vendor 0x16c0, in a signed `.app` that is listed and switched on under Input Monitoring before it runs. Check the grant in the TCC database.
- **Sender field:** a listen-only tap printing every non-zero integer field 0 to 255, while `vhid pointer play` runs and then a person moves the trackpad; for keys, `vhid press f16`, filtered to key code 106.

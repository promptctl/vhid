# How vhid works

This page is for someone who has cloned the repository and wants to change it. It covers
the processes vhid runs, the path one key press takes through them and why each boundary
sits where it does, the package and module map, and where to start reading.
[development.md](development.md) covers building and testing.

## One key press, end to end

```
 you, a script, or an agent
        │   vhid type "hi"                     your user, your session
        ▼
 ┌──────────────────────────┐
 │ vhid  (CLI, or vhid mcp) │  text → key presses on YOUR layout; screen point → pointer deltas
 └──────────────────────────┘
        │   XPC to the Mach service ai.promptctl.vhid.vhidd
        │   one HID report per call, each acknowledged before the next
        ▼
 ┌──────────────────────────┐
 │ vhidd  (root, launchd)   │  admits only callers signed by its own certificate;
 └──────────────────────────┘  one client at a time; owns the two devices
        │   Unix domain socket, pqrs's framing   (the socket's directory is root-only)
        ▼
 ┌──────────────────────────────────────┐
 │ Karabiner-VirtualHIDDevice-Daemon    │  pqrs's process; the only one entitled
 └──────────────────────────────────────┘  to open the driver
        │
        ▼
 ┌──────────────────────────────────────┐
 │ Karabiner-DriverKit-VirtualHIDDevice │  a DriverKit extension: macOS sees a
 └──────────────────────────────────────┘  keyboard and a mouse
```

Every hop exists because of something macOS requires. Working from the bottom up:

**pqrs's daemon is the only way into the driver.** Opening the driver extension takes an
entitlement Apple grants per application, and only pqrs's own daemon holds it. Being root
doesn't help. So vhid talks to that daemon, over the socket it serves
([`VirtualHID/DaemonConnection.swift`](../Sources/VirtualHID/DaemonConnection.swift)).
`vhidd` starts the daemon itself when nothing else has
([`vhidd/DaemonProcess.swift`](../Sources/vhidd/DaemonProcess.swift)), because the
public driver package registers no job to run it.

**That socket is root's, so a root process has to own the devices.** That is `vhidd`, a
launchd daemon. It brings the devices up, keeps them up, and retries with backoff while
the driver is off. In the meantime it refuses every act with the reason and the driver's
current step ([`vhidd/Readiness.swift`](../Sources/vhidd/Readiness.swift)).

**`vhidd` is kept too small to make the mistakes that matter.** The protocol between the
CLI and the daemon ([`Helper/HelperService.swift`](../Sources/Helper/HelperService.swift))
carries keys down, all keys up, a held set of keys, the same three for buttons, pointer
deltas, wheel ticks, and a cursor read. It can't express text or a screen position, and
both omissions are deliberate:

- *Text* becomes keys through a keyboard layout. macOS answers "which layout?" per
  process, and a root daemon is always told US. If `vhidd` were handed text, a Dvorak user
  would get the wrong characters typed while every check passed. So the CLI, running as
  you, turns text into key presses
  ([`Input/Typist.swift`](../Sources/Input/Typist.swift),
  [`KeyboardLayouts/`](../Sources/KeyboardLayouts)).
- *Positions* aren't something a mouse can say. It reports movement, and macOS
  accelerates that movement. So the CLI steers: a report every 8 ms along a person's
  trajectory, each aimed from where the cursor was read, then a closed loop that sends a
  delta, reads the cursor back and repeats until it lands
  ([`Input/Pointer.swift`](../Sources/Input/Pointer.swift),
  [design/human.md](design/human.md)). Replay can't
  read back between recorded moves that arrive milliseconds apart, so it steers from an
  acceleration table measured once before the clock starts
  ([`Input/Steering.swift`](../Sources/Input/Steering.swift),
  [design/replay.md](design/replay.md)).

**One report per call, and the client paces.** An acknowledgement from `vhidd` means the
report reached the driver, not that it landed: in twelve 500-character runs with every
report awaited, six landed fewer keys than were acknowledged, as few as 469. `vhidd`
can't see that loss, since the only receipt is an event tap in the user's session. So
the daemon takes one report per call and the client decides when the next one goes; a
count `vhid` reports is what was posted and acknowledged, an upper bound on what
landed ([`Helper/HelperService.swift`](../Sources/Helper/HelperService.swift)). Each call
still waits for its acknowledgement, on a serial queue of its own
([`Input/DeviceQueue.swift`](../Sources/Input/DeviceQueue.swift)), so the wait blocks
neither the caller's actor nor Swift's shared thread pool.

**The cursor and the display layout are read in the session in front.** Anywhere else, the window server answers
(0, 0) as if it were a real position. That would break clicks at the login window, or
after fast user switching. And a process stays tied to the first session it reads in. So
`vhidd` runs a child of itself that joins the front session, and starts a new one when
another session comes to the front
([`vhidd/FrontScreen.swift`](../Sources/vhidd/FrontScreen.swift)).

## Who may call the daemon

The Mach service is reachable by any process on the Mac, so reach can't be the boundary.
`vhidd` reads the certificate it was itself signed with and admits only callers signed by
that same certificate. It checks the caller by audit token, not by pid, so a reused pid
can't slip through ([`vhidd/CallerIdentity.swift`](../Sources/vhidd/CallerIdentity.swift)).
A release is signed with promptctl's Developer ID. A development build is signed with a
self-signed `vhid Dev` certificate that `make` creates on first run.
This is why bare `swift build` doesn't work: it signs ad hoc, there's no certificate to
match, and the daemon refuses every call.

The devices then go to one connection at a time. The first act claims them, and a second
client is refused with the holder's pid
([`vhidd/Holder.swift`](../Sources/vhidd/Holder.swift),
[`vhidd/Seat.swift`](../Sources/vhidd/Seat.swift)). Each CLI run, and each MCP tool call,
connects, acts, and leaves. Nothing holds the devices between calls. If a client leaves a
key down past a time limit, `vhidd` releases it, so a crashed caller can't leave a key
repeating forever.

[security.md](security.md) puts all of this in terms of what it allows and refuses.

## Two installations side by side

An installation is one string, the Mach service name, from which the launchd label, the
log subsystem and the rest are built
([`Installations/Installation.swift`](../Sources/Installations/Installation.swift)). The
package installs `ai.promptctl.vhid.vhidd`. A build from this tree talks to
`ai.promptctl.vhid.vhidd.dev`, which `make dev-daemon` registers. So you can develop
against a working daemon while the installed one keeps running. Nothing branches on which
installation it is; it asks the value for the name it needs.

## The other processes

- **`vhid doctor`** reads six requirements as this Mac stands: the driver extension, the
  launchd job, the daemon's answer, the signature it admits, who holds the devices, and
  the keyboard type macOS filed for the virtual keyboard
  ([`Doctor/`](../Sources/Doctor)). It changes nothing.
- **`vhid-menubar`** polls the same readings every five seconds and walks a person through
  the unmet ones ([`MenuBar/`](../Sources/MenuBar), [`vhid-menubar/`](../Sources/vhid-menubar)).
- **`vhid-record.app`** is the event tap behind `vhid record`. It is an app, launched
  through LaunchServices, so that it holds its own Input Monitoring permission and the
  terminal doesn't need it. It talks to the command over a socket
  ([`RecordingTie/`](../Sources/RecordingTie), [`vhid-record/`](../Sources/vhid-record)).
- **Keyboard Setup Assistant.** macOS opens it the moment a new keyboard appears, and it
  swallows the first keystrokes. `vhidd` files the assistant's answer for its own
  keyboard first, so the question is never asked
  ([`vhidd/KeyboardTypeAnswer.swift`](../Sources/vhidd/KeyboardTypeAnswer.swift)).

## eyes, the half that reads the screen

eyes reads the screen so that input can be aimed, and links nothing of the devices': no
target of either half links the other's, and only the `vhid` executable links both
([development.md](development.md#two-halves)). That is what lets one server, `vhid mcp`,
serve `look` beside the acts.

Two readers answer the same query. The tree reader walks the accessibility tree
([`eyes/Sources/Tree/`](../eyes/Sources/Tree)). The pixels reader runs Vision's text
recognition on a screen capture ([`eyes/Sources/Pixels/`](../eyes/Sources/Pixels)).
`MergedReader` asks both and reports a thing they both saw once. Every reader's candidates
are judged by one rule, so "matches" means the same thing whichever reader looked
([`eyes/Sources/Seeing/Reader.swift`](../eyes/Sources/Seeing/Reader.swift)). One answer
reads the frontmost app, the running apps, the windows and the displays once, as a `Desk`
([`eyes/Sources/Seeing/Desk.swift`](../eyes/Sources/Seeing/Desk.swift)), so its parts
cannot disagree about what was in front. What `look` was asked is parsed once, for the
tool and `vhid look` alike, into an `Asked`
([`eyes/Sources/Verbs/Asked.swift`](../eyes/Sources/Verbs/Asked.swift)).

macOS charges a privacy grant to the *responsible* process, such as the terminal or the
MCP client, not to `vhid`. So [`Grants`](../eyes/Sources/Grants/Grants.swift) names that
app, in `vhid doctor` and in a refusal, and a small C target, `Responsibility`, asks macOS
which one it is.

A look asks nothing of the daemon, so it waits behind no act: under `vhid mcp`, only the
acts take turns with one another
([`eyes/Sources/Turns/`](../eyes/Sources/Turns)). Vision recognises one image at a time
per process, gated the same way.

## Every run leaves a record

Each `vhid` run and each MCP tool call is one unit of work, recorded with its outcome
(ok, failed or cancelled), its duration, what it answered and why it failed. The units
inside it, such as a look's reading of the front app, are recorded with it on one trace,
each naming its parent. Records go to an OpenTelemetry collector when one is configured,
and to `~/Library/Logs/vhid/events.jsonl` otherwise; both halves record through the one
[`Telemetry`](../eyes/Sources/Telemetry/Telemetry.swift) target. The report counts are
taken where every report passes ([`vhid/Devices.swift`](../Sources/vhid/Devices.swift)),
so a run that connected and sent nothing says zero. The daemon logs to the unified log
under its installation's service name.

## Code map

The devices' half, by layer. Lower rows depend on nothing above them.

| Module | What it is |
|---|---|
| `vhid` | the CLI and `vhid mcp`: argument parsing, the verbs, the MCP tools |
| `vhidd` | the root daemon: admission, the holder, readiness, the front-session cursor |
| `vhid-menubar`, `MenuBar` | the menu bar item and its setup walk |
| `vhid-record`, `RecordingTie` | the recording app and its socket to the command |
| `Doctor` | the six readiness requirements |
| `Input` | the typist, the pointer and steering, chords, gestures, play and record formats |
| `Helper` | the XPC protocol between CLI and daemon, and both ends of it |
| `VirtualHID` | pqrs's socket protocol: framing, connection, the two devices |
| `DriverExtension` | reading and naming the driver extension's state; the pinned package |
| `KeyboardLayouts` | a layout's characters mapped back to the keys that type them |
| `Keystrokes`, `Pointing` | key usages, key codes, buttons: plain values |
| `Installations` | an installation's names, built from one string |
| `ChildProcess` | starting a child and running a command to its deadline or its stop, for both halves |
| `ScreenSpace` | the one screen space both halves speak: a point, a box, how each is spelled, and the display layout |
| `Signals`, `Version` | catching signals, the build's version |

The rest of the tree:

| Path | What it is |
|---|---|
| `eyes/` | the half that reads the screen: `Seeing`, `Tree`, `Pixels`, `Grants`, `EyesVerbs` and the `eyes` command line, with `Telemetry` and `Turns`, which both halves use |
| `Tests/` | test targets, each named for what it tests (`Signals`, `Version` and the two apps have none); `OwnThread` and `TestClock` are helpers for tests |
| `claude-plugin/`, `.claude-plugin/` | the Claude Code plugin: skills, the session-start check, the marketplace entry, and `VERSION`, the one place the version is written, which `scripts/version` reads for every build |
| `pkg/`, `scripts/make-pkg`, `scripts/notarize` | building, signing and notarizing the package |
| `scripts/` | every other build, check and release script; each says what it does in its header |
| `site/` | the GitHub Pages site and its filmed demos |
| `docs/design/` | measured design notes ([index](design/README.md)) |

## How it is tested

Unit tests drive the verbs against fakes: a keyboard that records instead of typing, and
a mouse with an acceleration curve of its own
([`Tests/vhidCLITests/Fakes.swift`](../Tests/vhidCLITests/Fakes.swift)). The protocol
tests put a fake pqrs daemon on the far end of a socket pair. Nothing in `make test`
moves the pointer of the Mac running it.

A test that blocks its thread runs in a suite marked `@Suite(.ownThread)`, and `make test`
narrows Swift's thread pool to one thread so that a missing mark shows up as a hang on any
Mac ([development.md](development.md#tests-that-wait)).

What only a real Mac can show, such as whether a key press lands at the lock screen, is
measured by hand on a test Mac and written up in `docs/design/`. `scripts/reach` re-checks
the reach table's rows.

## Where to start reading

Follow one `vhid type` call down:

1. [`Sources/vhid/TypeCommand.swift`](../Sources/vhid/TypeCommand.swift): the verb.
2. [`Sources/Input/Typist.swift`](../Sources/Input/Typist.swift): text proven typeable,
   then pressed.
3. [`Sources/Helper/HelperConnection.swift`](../Sources/Helper/HelperConnection.swift):
   the XPC call.
4. [`Sources/vhidd/Seat.swift`](../Sources/vhidd/Seat.swift): the daemon's side.
5. [`Sources/VirtualHID/VirtualKeyboard.swift`](../Sources/VirtualHID/VirtualKeyboard.swift):
   the report on the wire to pqrs.

The doc comments carry the reasoning, usually with the measurement behind it. Tags like
`[LAW:single-enforcer]` name the design rule a choice follows.

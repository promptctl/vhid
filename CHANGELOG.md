# Changelog

Each release's section is its GitHub Release notes, which keep line breaks, so each paragraph and item is one line. `[Unreleased]` lists what `master` has that the latest release does not; at a release its items move under the new version's heading and the empty heading stays, and the link definitions at the foot gain the new version's and compare `[Unreleased]` from its tag.

## [Unreleased]

- `vhid click`, `move`, `scroll` and `drag`, and their MCP tools, take a box as well as a point: `x,y,width,height`, the box `eyes find` prints beside each point (the MCP tools' `box`, and a string for `drag`'s `from` and `to`). Given a box, the pointer lands on a point drawn inside it, spread about the centre as a person's clicks are and never within 2 points of its edge (a side too narrow for that is aimed at its centre, and one under a point is refused), and the move takes as long as Fitts' law gives for a target that size. A point is pressed exactly, as before. Each move's `paths` entry has the point it `aimed` at, the `box` it was drawn inside, where it `landed`, and its `fitts_width`.
- `eyes find` and `eyes read`, and their MCP tools, print each row's box beside its point: `x,y,width,height` in the same screen points, the form `--rect` takes, covering the run and holding the point. The text and role move one column right. A row the accessibility tree found is cut to the part of its element's frame where the system's hit test lands a click on that element: Safari gives a page's native-looking button a frame several points wider than the button, and a click inside that frame pressed the page beside it. A rounded button's corners are checked too. The scope line says how many boxes were cut and how many could not be checked and why, and each look's record counts them as `boxes_narrowed` and `boxes_unchecked_unanswered`, `_elsewhere` and `_over_time`, with the `box_calls` the checks made and the `box_ms` they took.
- `vhid move`, `click`, `drag` and `scroll`, and their MCP tools, move the pointer as a hand does: a report every 8 ms along a slightly curved path that speeds up and slows down, stops a little short and corrects, taking about as long as Fitts' law says a person would, about 0.8 s across 740 points. In 0.4.1 a move of any length was three or four jumps in under 50 ms. Where the button goes down is read back and lands as near the point as it did. Each run's record has the `seed` its moves were drawn from and each move's `paths` entry. `vhid play` replays its script's own motion, as before.
- `vhid scroll --vertical N` and `--horizontal N`, and the MCP tool `scroll`'s `vertical` and `horizontal`, scroll N times as far as 1: each notch is its own report, 200 to 300 ms after the last, varied, so a roll of N takes about N × 230 ms. In 0.4.1 the ticks went out up to 127 to a report, and macOS reads each report as a single notch, so in Safari a roll of any size barely moved the page.
- `vhid click` and `drag`, and their MCP tools, rest on the point about a quarter of a second before the button goes down and hold it about a tenth of one, and the clicks of a double or triple click come about 120 ms apart, inside the Mac's double-click interval. `scroll` rests before its first notch. In 0.4.1 the button went down the moment the move ended and came up a millisecond later, and web menus that take a click only on an item the pointer has rested on ignored it. Each run's record totals its `pauses` by kind.
- Every `vhid` run and every MCP tool call leaves one JSON record, with its outcome, its duration and the reports and notches it sent, in `~/Library/Logs/vhid/events.jsonl`, or sent to the OpenTelemetry collector `OTEL_EXPORTER_OTLP_ENDPOINT` names. Only a run ended by a second signal leaves none. `docs/cli.md` in the repository describes the record's fields.
- Control-C or `SIGTERM` stops a `vhid` verb, which is recorded `cancelled` with what it had sent and `attributes.signal` naming the signal, says so on stderr, and dies by the signal. `doctor`, `driver` and `service` are stopped the same way, ending the command they were running to read the Mac, and so is a `doctor` MCP call that is withdrawn. `vhid mcp` withdraws the tool calls it is running or has queued, as a client's cancel would, and each call's record names the signal. `vhid record` still answers the signal by finishing and printing the script it recorded, and is cancelled, printing none, only when signalled before the tap app is recording.

## [0.4.1]

- Homebrew 7 no longer warns that the cask calls the deprecated `postflight` on every brew command that reads it: the cask copies what uninstall needs at install, with `postflight_steps`.

## [0.4.0]

- `vhid type` and `vhid press` take `--into <app>`, and the MCP tools `into`: with another app in front just before the first key, nothing is sent and the refusal names the app that was. The app is named as `eyes windows` prints the frontmost application. They refuse the same way at the login window or with another user's session in front.
- `vhid gesture <name>` does what a trackpad gesture does, by pressing the key that does it: back and forward, zoom in and out, Look Up, the next or previous Space, Mission Control, App Exposé, Show Desktop, Launchpad and Notification Center. A system shortcut is the one the user has set, and one that is off is refused, naming the setting. `vhid mcp` serves it as the `gesture` tool.
- `vhid mcp` and `eyes mcp` answer a client's initialize with instructions: each names the other server, says the point `find` prints is the point `click` takes, and teaches the look, act, look again loop, so a client without the Claude Code plugin learns the pairing too.
- The Claude Code plugin has a second skill, `menu-item`, which invokes any app's menu item by its name: it searches for the item from the app's Help menu and checks the result before choosing it, and clicks down the menu path for an item in the Help menu itself.
- `eyes find` and `eyes read` print each row's role, such as `AXButton`, or `pixels` for text only the pixels reader saw, as a third column before a near miss's edit count.
- `eyes find --page <window id>` and `eyes read --page <window id>` read only the web page a browser window shows, not its toolbar and bookmarks. The MCP tools take `page`.
- `eyes find --near <text>` orders matches by how close each sits to that text, so `eyes find Remove --near Beta --limit 1` gives the Remove button in Beta's row. The MCP tool takes `near`.
- Over ssh, `eyes grants` names `sshd-keygen-wrapper`, the program macOS holds the grants under, where it named `sshd-session`, whose switch does nothing.
- In Chrome, `eyes find` no longer answers an element scrolled out of view as a match on the viewport's edge, where a click misses it.
- Removing the driver, by `vhid-uninstall --driver` or `brew uninstall --zap --cask vhid`, no longer fails in the moment after a deactivation while macOS tears the driver down; `vhid driver` and `vhid doctor` name that moment `withdrawing`.
- The Homebrew cask reaches this release, and with it the `brew uninstall --zap` and `brew uninstall` behavior 0.3.0's notes describe: 0.3.0 itself never reached the cask, which stayed at 0.2.0.

## [0.3.0]

- A Claude Code plugin, `/plugin marketplace add promptctl/vhid` then `/plugin install vhid@vhid`, adds the `vhid` and `eyes` MCP servers, a skill for the look, act, look again loop, and a check at the start of each session that tells the agent when vhid is missing or not `ready`.
- `brew uninstall --zap --cask vhid` removes the pqrs driver package with vhid, refusing as `vhid-uninstall --driver` does, for instance while Karabiner-Elements is installed. On an install made or upgraded with this release's cask, `brew uninstall --cask vhid` also works after `vhid-uninstall` has been run by hand.

## [0.2.0]

- vhid is a Homebrew cask: `brew install --cask promptctl/tap/vhid` installs the newest release's pkg, and `brew uninstall --cask vhid` removes it as `vhid-uninstall` does.
- `vhid click`, `move`, `scroll`, `drag` and `cursor` work at the login window and behind fast user switching: vhidd reads the cursor in the session in front. In 0.1.0 a cursor read made there answers (0, 0), so those verbs cannot place the pointer.
- `vhid type` and `vhid press` take `--layout <input source id>`, and the MCP tools `layout`, to type on a keyboard layout other than the caller's. With none named and the system reporting no current layout at all, they type with US English; in 0.1.0 they refuse.
- `eyes find --until present|absent` waits for text to appear or go, for as long as `--timeout` allows, on the command line and as the MCP tool.
- `eyes grants` says whether Screen Recording and Accessibility are held and which app macOS charges them to, without prompting; `eyes grants --ask` raises macOS's dialogs. `eyes mcp` serves `grants` as a tool.
- A grant switched on while `eyes mcp` is running counts from its next call. In 0.1.0, quit and reopen the client after granting.
- The menu bar item's **Set Up vhid…** walks the requirements that are not met, one page at a time.
- `eyes` emits one JSON event per look and per grant reading, to the OTLP collector `OTEL_EXPORTER_OTLP_ENDPOINT` names or to `~/Library/Logs/eyes/events.jsonl`.
- The accessibility tree reader no longer takes Notification Center's full-screen widget window as covering every window behind it.
- Both MCP servers answer every request once, and a session whose input has ended waits for the calls still running.
- Installing over a running daemon waits for launchd to let go of its job before loading the new one, which launchd had refused with error 5.
- vhidd names itself `vhidd` in everything it prints and logs.
- A command vhid or vhidd runs, such as `pkgutil`, `systemextensionsctl` or `ioreg`, is stopped at a time limit and named in the error. In 0.1.0 one that never ended left a client with no answer and vhidd's bring-up loop waiting for good.
- When the driver extension stops while vhidd is serving, vhidd takes the devices down, refuses every verb with the reason and the driver's step, and brings them up again once the driver is back, with no restart. In 0.1.0 `vhid doctor` went on printing `ready` and, while the driver stayed off, the verbs typed and moved nothing.
- vhidd brings the devices up within seconds of the driver extension being turned on: it looks at the driver every two seconds while it waits to try again.
- A verb refused while the driver extension is off names the step the driver is at now. In 0.1.0 it names the step read when vhidd last tried, for up to a minute after that step is done.

## [0.1.0]

The first release: a virtual keyboard and mouse that macOS sees as hardware, driven from the command line or over MCP, and a screen reader that finds what to click. Requires macOS 15 or later.

- `vhid type`, `press`, `click`, `move`, `scroll` and `drag` drive the two virtual devices, and `vhid cursor` says where the pointer is.
- `vhid play` replays a timed script of keyboard and mouse acts; `vhid record` writes that script from the physical keyboard and mouse.
- `vhid doctor` names every requirement the verbs need and the step left for any that is not met; the menu bar item shows the same reading.
- `eyes windows`, `displays`, `find` and `read` say what is on screen and where, in the coordinates `vhid click` takes.
- `vhid mcp` serves `type`, `press`, `click`, `move`, `scroll`, `drag`, `play`, `cursor` and `doctor` as MCP tools, and `eyes mcp` serves `windows`, `displays`, `find` and `read`.
- `vhid --version` and `eyes --version` print the release, and both MCP servers report it.
- One signed, notarized pkg installs both CLIs, the root daemon that owns the devices, the menu bar item, the `vhid record` tap, an uninstaller, and the pinned Karabiner-DriverKit-VirtualHIDDevice package.
- After installing, turn on `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice` under System Settings > General > Login Items & Extensions > Driver Extensions; no installer can do this for you. `vhid doctor` prints `ready` once everything vhid needs is met.

[Unreleased]: https://github.com/promptctl/vhid/compare/v0.4.1...master
[0.4.1]: https://github.com/promptctl/vhid/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/promptctl/vhid/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/promptctl/vhid/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/promptctl/vhid/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/promptctl/vhid/releases/tag/v0.1.0

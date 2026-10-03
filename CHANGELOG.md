# Changelog

Each release's section is its GitHub Release notes, which keep line breaks, so each paragraph and item is one line. `[Unreleased]` lists what `master` has that the latest release does not; at a release its items move under the new version's heading and the empty heading stays, and the link definitions at the foot gain the new version's and compare `[Unreleased]` from its tag.

## [Unreleased]

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

[Unreleased]: https://github.com/promptctl/vhid/compare/v0.3.0...master
[0.3.0]: https://github.com/promptctl/vhid/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/promptctl/vhid/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/promptctl/vhid/releases/tag/v0.1.0

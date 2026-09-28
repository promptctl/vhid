# Changelog

Each release's section is its GitHub Release notes, which keep line breaks, so each paragraph and item is one line.

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

[0.1.0]: https://github.com/promptctl/vhid/releases/tag/v0.1.0

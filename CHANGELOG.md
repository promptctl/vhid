# Changelog

Each release's section is its GitHub Release notes.

## [0.1.0]

The first release: a virtual keyboard and mouse that macOS sees as hardware, driven from
the command line or over MCP.

- `vhid type`, `press`, `click`, `move`, `scroll`, `drag` and `cursor` drive the two
  virtual devices; `vhid play` replays a timed script of keyboard and mouse acts, and
  `vhid record` writes that script from the physical keyboard and mouse.
- `vhid mcp` serves the same verbs as MCP tools over stdin and stdout.
- `vhid doctor` names every requirement the verbs need and the step left for any that is
  not met; the menu bar item shows the same reading.
- `eyes` reads the screen: `windows` and `displays`, and `find` and `read` for the
  accessibility tree and pixels.
- One signed, notarized pkg installs the CLI, `eyes`, the root daemon that owns the
  devices, the menu bar item, the `vhid record` tap, an uninstaller, and the pinned
  Karabiner-DriverKit-VirtualHIDDevice package.
- After installing, turn on `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice` under
  System Settings > General > Login Items & Extensions > Driver Extensions. No installer
  can do this for you; `vhid doctor` prints `ready` once it is on.

[0.1.0]: https://github.com/promptctl/vhid/releases/tag/v0.1.0

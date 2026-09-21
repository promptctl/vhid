# vhid

A virtual keyboard and a virtual mouse for macOS, driven from a CLI or over MCP.

It creates two HID devices through the
[Karabiner-DriverKit-VirtualHIDDevice](https://github.com/pqrs-org/Karabiner-DriverKit-VirtualHIDDevice)
driver extension and posts reports to them. To macOS the input is indistinguishable
from hardware: no event taps, no Accessibility grant, no window-server synthesis.

**It is a driver, not a nanny.** It types what it is told to type and clicks where it
is told to click. Which app is in front, whether a dialog is covering it, and whether
you meant to do this are not its questions to ask.

Extracted from [low-talker](https://github.com/promptctl/low-talker), whose dictation
typed through this stack first.

## Two packages

The repository holds two SwiftPM packages, and the root manifest deliberately does not
mention the second one.

| | what it is | build and test |
|---|---|---|
| `.` | the devices: the keyboard, the mouse, and the root daemon that owns them | `swift build && swift test` |
| `eyes/` | reading the screen: where the windows are, and the vocabulary an accessibility reader and an OCR reader both speak | `cd eyes && swift build && swift test` |

`eyes` finds a coordinate; `vhid click` presses it. Nothing joins them in code — only that
workflow. A target in the root manifest would be one `dependencies:` line away from
linking the two, and nothing in review catches that line, so the separation is a package
boundary rather than a rule someone has to remember.

The cost of that isolation is this paragraph: `swift test` at the root does not run
`eyes`' tests, and nothing but this table says so.

## Status

Under construction. Nothing here is released yet.

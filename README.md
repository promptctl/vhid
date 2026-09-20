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

## Status

Under construction. Nothing here is released yet.

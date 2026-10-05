# Design notes

These notes record what was measured on a real Mac before a decision was made, and what
the measurement showed. Read one when you want to know why vhid does something the way
it does, or before changing it. Each note opens with what it found, then gives the date,
the macOS version and the hardware, then how each result was shown, so you can repeat it.

| Note | The question it answers |
|---|---|
| [remote-hands.md](remote-hands.md) | Where does input from vhid's devices land: the lock screen, the login window, password prompts, Secure Keyboard Entry? |
| [replay.md](replay.md) | What does a recording look like, where does `vhid record` read input from, and how does `vhid play` steer the pointer between recorded points? |
| [gestures.md](gestures.md) | With no trackpad, which keys, buttons and clicks do what each trackpad gesture does? |
| [trackpad.md](trackpad.md) | Could vhid present a virtual trackpad instead? (Not without an entitlement from Apple.) |
| [menus.md](menus.md) | Which route reaches a menu item that has no shortcut: the Help menu's search, clicking down the menus, or an App Shortcut? |
| [browser.md](browser.md) | How far does finding text with `eyes` and clicking it with `vhid` get in Safari, Chrome and Firefox? |

The probes the notes ran are kept beside them: `trackpad-probe.c` and
`trackpad-mtwatch.c` for the trackpad note, `browser-probe.html` for the browser note.

A finding a later version could change is dated, so check the date against the code
before you rely on it. When a change rests on a new measurement, add a note in the same
shape: the finding first, then the setup, then how each result was shown.

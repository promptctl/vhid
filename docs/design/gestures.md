# Trackpad gestures: which ones vhid's devices reach

No trackpad gesture reaches macOS as a gesture through vhid's devices. The driver presents a keyboard and a mouse, and nothing a gesture is built from: no touches, no digitizer. What vhid can reach is what each gesture *does*. Almost every gesture's action has a keyboard shortcut, a mouse button or a click that gets the same result, and on studious each of those worked. The exception is smart zoom, which has no route of its own. Rotate has one only where an app offers a rotate command.

Measured on studious on 2026-10-03: macOS 15.0.1, Safari 18.0.1, Chrome 154, Maps 3.0, TextEdit, Preview; vhid 0.2.0, eyes 0.3.0-dev+a5e9794. Every act went through vhid's devices. Each result was checked by what changed on screen: the URL eyes read in the address bar, or a `screencapture` taken over ssh.

## Each gesture and its route

| Gesture | What it does | Route through the devices | On studious |
| --- | --- | --- | --- |
| Two-finger scroll | scrolls | the wheel: `vhid scroll` | vhid's existing verb |
| Two-finger click | secondary click | the right button: `vhid click --button right` | vhid's existing verb |
| Tap to click, three-finger drag | click, drag | the left button: `vhid click`, `vhid drag` | vhid's existing verbs |
| Two-finger swipe left or right | back or forward a page | ⌘[ and ⌘] | worked in Safari and Chrome |
| | | buttons 4 and 5: `vhid click --button 4` | worked in Chrome; did nothing in Safari |
| | | the horizontal wheel | did nothing in either |
| Pinch | zoom in or out | ⌘= and ⌘- | zoomed Safari's page and Maps' map |
| Two-finger double-tap | smart zoom on the block under the pointer | none; ⌘= zooms the whole page instead | |
| Two-finger rotate | rotates | the app's own command, where it has one: Preview's ⌘R and ⌘L | worked in Preview |
| Force click, three-finger tap | Look Up | select the word, then ⌃⌘D | worked in TextEdit |
| Three- or four-finger swipe left or right | next or previous Space or full-screen app | ⌃→ and ⌃← | worked between the desktop and a full-screen TextEdit |
| Three- or four-finger swipe up | Mission Control | its shortcut: ⌃↑ by default, ⌥Q on studious | worked |
| Three- or four-finger swipe down | App Exposé | its shortcut: ⌃↓ | worked |
| Spread thumb and three fingers | Show Desktop | its shortcut: F11 | worked; F11 again brought the windows back |
| Pinch thumb and three fingers | Launchpad | no shortcut by default; ⌘Space, type `Launchpad`, Return | opened through Spotlight |
| Two-finger swipe in from the right edge | Notification Center | click the date and time in the menu bar | worked; Escape closed it |

## What the measurements found

**Mission Control's shortcuts belong to the user.** On studious, Mission Control is ⌥Q, not the default ⌃↑. A route that presses the default would do nothing there, or would do whatever the user bound that key to. The bindings are under System Settings > Keyboard > Keyboard Shortcuts > Mission Control, and are stored as numbered entries in `~/Library/Preferences/com.apple.symbolichotkeys.plist`: 32 Mission Control, 33 App Exposé, 36 Show Desktop, 79 and 81 one Space left and right, 160 Launchpad. Each entry has `enabled` and its `parameters`: the character, the virtual key code and the modifier flags. On studious, 32 read `[113, 12, 524288]`, which is q, key code 12 and Option. Launchpad's entry 160 was disabled and had no key.

**The horizontal wheel does not swipe between pages.** Ten ticks sent as one act, and 41 single-tick reports 16 ms apart, in both directions, left Safari and Chrome on the page they were on. The single ticks rule out vhid packing its ticks into one report (vhid-scroll-1m8). Back and forward are ⌘[ and ⌘], which both browsers took. Chrome also took buttons 4 and 5, and Safari ignored them.

**The wheel does not pinch.** In Maps, the wheel panned the map and ⌘= zoomed it. ⌃ held while scrolling did nothing in Safari, because the Accessibility zoom setting that uses it, "Use scroll gesture with modifier keys to zoom", is off on studious, as it is by default.

**App Exposé takes a while to appear.** A capture 1.2 s after ⌃↓ showed the desktop unchanged, and one 2.5 s after showed App Exposé. Mission Control had shown at 1.2 s. Wait for the screen to change before acting on it.

**The hidden Dock did not appear under vhid's pointer.** studious hides its Dock on the left edge. Moving the pointer to x 0, and then pushing it left with 21 more move reports, did not reveal the Dock, so Launchpad's Dock icon was out of reach. Spotlight reached Launchpad instead. Why the Dock stayed hidden was not looked into.

## What the driver offers

The pointing device (`org_pqrs_Karabiner_DriverKit_VirtualHIDPointing`, driver 1.8.0) reports 32 buttons, X and Y motion, a vertical wheel and a horizontal wheel (AC Pan). The keyboard device reports four input collections: the keyboard page (report 1), the consumer page (report 2), Apple's top case page (report 3) and Apple's vendor keyboard page (report 4). Neither device has a digitizer page or any touch report, so a trackpad gesture cannot be described to macOS through them. Whether a virtual trackpad could is vhid-shortcuts-1sl.7ld's question.

Apple's vendor keyboard page has usages for Spotlight (0x01), Launchpad (0x04), Mission Control (0x10, `expose_all`) and Show Desktop (0x11, `expose_desktop`), the keys an Apple keyboard's top row sends. vhid posts only report 1 (`KeyboardReport` in `Sources/VirtualHID/VirtualKeyboard.swift`), so it cannot send them today. Whether macOS acts on them from the virtual keyboard was not measured. If it does, they would reach Mission Control and Launchpad whatever shortcuts the user has set.

## Repeating it

On studious, with vhid at `/usr/local/bin/vhid` and eyes at hand, and the app brought to the front with `open -a`:

- Back and forward: open two pages in one tab (⌘T, type the first, Return; ⌘L, type the second, Return), then read the address bar with `eyes read --rect` over the window's top 40 points after each act.
- Spaced wheel ticks: a `vhid play` script whose lines are `{"t_ms":<16·i>,"wheel":{"v":0,"h":1}}`.
- Spaces: ⌃⌘F puts TextEdit in a full-screen Space of its own; ⌃⌘F again takes it out.
- The shortcuts in force: `plutil -convert json -o - ~/Library/Preferences/com.apple.symbolichotkeys.plist`, then read the entries above.

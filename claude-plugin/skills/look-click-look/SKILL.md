---
name: look-click-look
description: Operate apps on this Mac through its real screen, keyboard and mouse - find a button or text with the eyes tools, click, type or press keys with the vhid tools, then look again to see what changed. Use when the user asks to click something, type into a field, press a shortcut, or read what an app, window or dialog shows ("click the Save button in TextEdit", "type my name into that field", "press Command-S", "what does the alert say"), including at the lock screen, the login window or a password prompt.
---

# Look, act, look again

vhid and eyes are two MCP servers that work as a pair. eyes reads the screen: what is in front, and where text is. vhid drives a virtual keyboard and mouse that macOS takes for hardware. A client with only one of them is half the pair; both come with vhid, served by `vhid mcp` and `eyes mcp`.

Every point either server prints or takes is the same screen point. The point eyes `find` prints is the point vhid `click` takes, as printed: no scaling, no offset, negative on a display left of or above the main one. Beside each point, eyes prints a box around the text that holds the point, as x,y,width,height in the same points: the form eyes' `rect` takes, and vhid `click`, `move` and `scroll` take it too, as `box`, and `drag` as `from` or `to`, pressing a point drawn inside it as a hand lands somewhere on a button rather than on its exact centre.

Neither server decides anything. `click` presses whatever is at the point it is given, `type` types into whatever has keyboard focus, and `find` reports what is on screen, not whether an act did what was meant. So work in a loop:

1. Look with eyes: `windows` for what is in front, `find` for where the text is.
2. Act with vhid on what you saw.
3. Look again at the same place. `find` with `until` and a `timeout` waits for the change; do not sleep and retry.

Done means a look after the act showed the change. An act's answer says the act happened, not what it did.

## Each step

1. **Look.** `windows` says what is in front and which app is frontmost. `find` with
   the text you want says where it is - `{"text": "Save"}`, narrowed with `window` or
   `display` when the text could be in more than one place. `read` gives every run of
   text in a window in reading order, for when you do not yet know what to look for.
   Each row is the point, the box around the run, the text, and what it is: the
   element's role, such as `AXButton` or `AXLink`, or `pixels` for text drawn with no
   element behind it.
   In a browser, pass `page` with the window's id instead of `window`: it reads the
   web page alone, so a bookmark or toolbar button with the same name is not a match.
   When the same label appears several times, such as a Remove button on every row,
   `near` orders the matches by the text beside each, so `{"text": "Remove", "near":
   "Beta"}` puts the Remove in Beta's row first.
2. **Act** on what you saw: `click` the box `find` printed, as `box`, or its point; `type` or `press` once
   the field or window that should receive the keys is in front.
3. **Look again** at the same place. `find` the result you expected - the dialog's
   title, the new text, the button gone. To wait for it, pass `until` (`present` or
   `absent`) and a `timeout`, which re-reads until it happens.

A `click` that answered "clicked left once at (812, 604) after 1 motion report" is an
act that happened, not an outcome: the press landed on that point, and what sat there
may have been something else. When the user asked for an outcome, such as a file
saved, a field filled or a sheet dismissed, you have it only once a look after the act
shows it.

## Before you type

Keys go wherever the keyboard is focused: another app's window, a chat, a terminal
that runs what it receives. Before `type` or any `press` that edits, confirm with
`windows` that the app you mean is frontmost, click into the field first when focus
could be anywhere else, and pass that app as `into`, copied from the frontmost
application `windows` printed. With `into`, the tool checks the app is still in front just before the first
key and refuses, sending nothing, when something else came forward; look again rather
than retrying blind. `into` checks the app, not the field, and a panel of another
process over it can still hold the keys. If you cannot confirm where the keys will
land, say so instead of typing.

## When a tool refuses

Each refusal names its reason and the step that fixes it. Pass that on to the user;
do not route around it.

- A vhid tool refused, or `doctor` says `not ready`: the row that is not met names
  the step. A driver extension is turned on only by the person at the Mac, under
  System Settings > General > Login Items & Extensions.
- `find` or `read` says a reader could not look: call `grants`. It names the app
  macOS charges Accessibility and Screen Recording to - the terminal running Claude
  Code, or whichever app started it. Tell the user to switch that app on under System
  Settings > Privacy & Security; a grant switched on counts from the next call.
- A tool says an argument is not one it takes: the installed vhid is older than this
  skill, which follows vhid's `master`. Tell the user; `brew upgrade --cask
  promptctl/tap/vhid` brings the latest release.
- `find` matched nothing: it lists the nearest runs and how many edits off each is.
  A misread one edit away is still the thing you were looking for.

You will be stuck at some point - a reader without its grant, a click refused - and
think "I can do this another way: `osascript`, `screencapture`, `cliclick`, a
CGEvent from Python." Do not. Those reach around the devices the user installed vhid
to use; they fail where vhid works (the lock screen, a password prompt, Secure
Keyboard Entry) and act where the user did not ask for them. Report the refusal and
its step.

## Shape of a run

```
eyes windows                         -> 4521  TextEdit  L0  ...  front: a save sheet on it
eyes find {"text": "Save", "exact": true, "window": 4521}
                                     -> 812,604	790,594,44,20	Save	AXButton
vhid click {"x": 812, "y": 604}      -> clicked left once at (812, 604) after 1 motion report
eyes find {"text": "Save", "exact": true, "window": 4521,
           "until": "absent", "timeout": 5}
                                     -> absent after 2 reads in 0.6s: the sheet changed
eyes read {"window": 4521}           -> the title bar reads notes.txt, no sheet: saved
```

The sheet going shows only that something changed: Cancel, or a "Replace?" sheet over
it, makes Save go too. The `read` after it is the look that shows the file saved.

Not this:

```
vhid click {"x": 812, "y": 604}      -> clicked left once at (812, 604) after 1 motion report
"Clicked Save."                       (no look before, no look after:
                                      nobody knows what was pressed)
```

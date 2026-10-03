---
name: look-click-look
description: Operate apps on this Mac through its real screen, keyboard and mouse - find a button or text with the eyes tools, click, type or press keys with the vhid tools, then look again to see what changed. Use when the user asks to click something, type into a field, press a shortcut, or read what an app, window or dialog shows ("click the Save button in TextEdit", "type my name into that field", "press Command-S", "what does the alert say"), including at the lock screen, the login window or a password prompt.
---

# Look, act, look again

Two MCP servers, one coordinate space. `eyes` reads the screen: `displays`, `windows`,
`find`, `read`, `grants`. `vhid` drives a virtual keyboard and mouse that macOS takes
for hardware: `click`, `type`, `press`, `move`, `scroll`, `drag`, `play`, `cursor`,
`doctor`. Every point either one prints or takes is the same screen point, so the
point `find` gives you is the point `click` takes, as printed - no scaling, no offset,
negative on a display left of or above the main one.

Neither server decides anything. `click` presses the point it is given whatever is
there, `type` types into whatever has keyboard focus, and `find` reports what is on
screen, not whether your last act did what you meant. Deciding is your job, and
looking is how you do it.

## The loop

1. **Look.** `windows` says what is in front and which app is frontmost. `find` with
   the text you want says where it is - `{"text": "Save"}`, narrowed with `window` or
   `display` when the text could be in more than one place. `read` gives every run of
   text in a window in reading order, for when you do not yet know what to look for.
2. **Act** on what you saw: `click` the point `find` printed; `type` or `press` once
   the field or window that should receive the keys is in front.
3. **Look again** at the same place. `find` the result you expected - the dialog's
   title, the new text, the button gone. To wait for it, pass `until` (`present` or
   `absent`) and a `timeout`, which re-reads until it happens; do not sleep and retry.

**Done means step 3 showed the change.** A `click` that answered "clicked left once
at (812, 604)" is an act that happened, not an outcome: the press landed on that point,
and what sat there may have been something else. When the user asked for an outcome
- a file saved, a field filled, a sheet dismissed - you have it only once a look
after the act shows it.

## Before you type

vhid does not check what it types into. Keys go wherever the keyboard is focused:
another app's window, a chat, a terminal that runs what it receives. Before `type` or
any `press` that edits, confirm with `windows` that the app you mean is frontmost, and
click into the field first when focus could be anywhere else. If you cannot confirm
where the keys will land, say so instead of typing.

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
eyes windows                                  -> TextEdit frontmost, window 4127
eyes find {"text": "Save", "window": 4127}    -> 812,604	Save
vhid click {"x": 812, "y": 604}               -> clicked left once at (812, 604)
eyes find {"text": "Save As:", "until": "present", "timeout": 5}
                                              -> the save sheet is open: done
```

Not this:

```
vhid click {"x": 812, "y": 604}               -> clicked left once at (812, 604)
"Clicked Save."                                  (no look before, no look after:
                                                  nobody knows what was pressed)
```

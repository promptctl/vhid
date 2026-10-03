---
name: menu-item
description: Invoke any app's menu item by its name on this Mac through its real keyboard and mouse - open the app's Help menu with vhid, search for the item, read the results with eyes, and choose it; or click down the menu path for items in the Help menu itself. Use when the user asks for a menu command, especially one with no shortcut ("choose File > Export as PDF in TextEdit", "use the Customize Toolbar menu item in Finder", "open Chrome's Task Manager from the Window menu", "invoke a menu command that has no shortcut"), or names a menu item in any app, in any language.
---

# Invoke a menu item by its name

The route is Help search: click the app's Help title, type the start of the item's
name, read the "Menu Items" rows, then Down and Return. It finds an item at any depth
without knowing its path, and lists items that appear only with Option held. Help
search does not search the Help menu itself, so an item there is clicked down its path.

Every step below is a look before an act; the look-click-look skill has the loop,
the before-you-type check, the `until`/`timeout` wait and what to do when a tool
refuses. One thing more than it says: eyes reads menus by pixels only. "…" reads as
"...", case drifts ("Go" reads "GO"), and a menu bar can read as one run. Never `find`
an item's full title with `exact`. Search with the start of its name; judge a row
against the whole name, loosely.

Not App Shortcuts, not `defaults write`, not `osascript` clicking menus: a shortcut
stays in the user's keyboard settings and rebinds the item for them too, and the
others reach around the devices.

## Help search

1. **Front.** `windows` - the app's rows are marked `front`. Check the rows, not the
   header: its "Frontmost:" name can differ from the owner ("Code" for "Visual
   Studio Code"). If the app is not in front, click one of its visible windows on the
   title bar, not content that could act, or its Dock icon found with `find`; then
   `windows` again, three looks in all, until its rows are `front`. Not `open -a`,
   not `osascript`.
2. **Find the Help title.** `find {"text": "Help", "rect": "0,0,800,30"}` - the strip
   of the main display's menu bar that reached Help in every app measured; widen the
   rect for an app with more titles. No titles in the strip (full screen, a hidden
   bar): `move {"x": 400, "y": 0}` to the top edge to show the bar; it slides in late,
   so find the title again with `until` `present` and a `timeout`.
   In a localized app the title is in its language ("Aide" in French); when you do
   not know the word, `read` the strip: Help is the last of the app's titles, the run
   after the Apple menu - not the rightmost text, which can be a status item or the
   clock. Several matches can come back: in TextEdit, `Edit` answers "TextEdit"
   first. Take the row whose text is the title alone, not the first row.
3. **Click it,** then **look that it opened**: `windows` shows a window owned by the
   app on layer 101. No layer-101 window means no menu - do not type. A keystroke sent
   when the menu did not open lands in the document behind it.
4. **Type the start of the name** as the app shows it, in the app's language
   ("Exporter au format PDF" in a French TextEdit), without its ellipsis:
   `type {"text": "Export as PDF"}`. Do not open search with ⇧⌘/: TextEdit's own Help
   took that key instead. The search field opens holding the last query, selected,
   with its results showing; your typing replaces it.
5. **Read the results:** `read {"window": <id>}` the layer-101 window; rows are
   point, text, role, and you compare the text. Down takes the first row under
   "Menu Items" (above "Help Topics"), whatever it is. That row must be the whole
   name, compared loosely: "..." for "…", drifted case, and a stray glyph before
   the name, which is the item's icon (TextEdit read `EJ Export as PDF...`). An item
   in a top-level menu shows no path (Chrome's Window > Task Manager reads `Task
   Manager`); only a submenu item does ("New Window with Profile > New
   Profile..."). The name plus more words is another item: `Close All` is not
   `Close`. If the first row is not the item, the list may still be the last
   search's: read again, three reads in all, no more. Still not first: type more of
   the name and read the same way; if it still is not first, take the path route.
6. **Choose it:** `press {"chords": ["down"]}`, then `press {"chords": ["return"]}`.
7. **Look for what it does:** a window, a sheet, or a changed state (a checkmark
   toggled, a panel shown or hidden). TextEdit's export sheet came back as a new
   window, larger than the document. `windows` for the new window; not there yet,
   look again, three looks in all - one empty look is not "nothing happened", nor a
   reason to run the item again. Then wait inside it: `find` something of the
   item's with `"window": <new id>`, `until` `present` and a `timeout`. Done means
   you saw it there. "Save" found in the document window proves nothing: a plain
   Save As sheet has it too.

   No new window, or nothing by the timeout: `windows`. A layer-101 window still
   there means the item did not run - often disabled, which Help search still
   lists. Escape until it is gone, one press per look, as in "No item matches", and
   tell the user the item was listed but did not run. While the menu is open, type
   and press nothing else.

## No item matches

The results read "No Results Found", or show Help Topics with no Menu Items. Then:

- `press {"chords": ["escape"]}`, then look with `windows`. The first escape only
  clears the search field; the menu stays open, reading "Search". Press escape again
  and look again, one press per look, until the layer-101 window is gone.
- Tell the user no menu item was found under that name in that app, and what you
  searched for.

Never press Return on a Help Topic, and never take some other row as a close enough
guess. If the item should be in the Help menu itself, take the path route instead.

## The path route

For an item in the Help menu, or one you know the path of when search misses it:
find the menu's title in the strip as in step 2, click it, look for the layer-101
window as in step 3, `read` it, and `click` the next row of the path. A row that is a
parent opens its submenu as another layer-101 window: find it with `windows`, `read`
it, and keep down the path until you click the item itself; only then look for what
it does, as in step 7. Every row is judged as in step 5: the whole name, loosely.

## Shape of a run

```
eyes windows      -> ... Frontmost: TextEdit (pid N), its rows marked front.
eyes find {"text": "Help", "rect": "0,0,800,30"}
                  -> (a scope line, then) 422,14	Help	pixels
vhid click {"x": 422, "y": 14}
eyes windows      -> 263	TextEdit	L101	395,25 360x59	front    the menu is open
vhid type {"text": "Export as PDF"}
eyes read {"window": 263}
                  -> 444,73	Menu Items	pixels
                     472,95	EJ Export as PDF...	pixels      first row, the whole name: this one
                     445,116	Help Topics	pixels
vhid press {"chords": ["down"]}
vhid press {"chords": ["return"]}
eyes windows      -> 272	TextEdit	L0	502,53 800x448	front     a new window
eyes find {"text": "Save", "window": 272, "until": "present", "timeout": 5}
                  -> a Save row at 1246,471, in the new window: the export
                     sheet: invoked
```

Not this:

```
vhid click {"x": 422, "y": 14}
vhid type {"text": "Export as PDF"}     (no layer-101 window was checked: the
vhid press {"chords": ["down"]}          click missed, "Export as PDF" went into
vhid press {"chords": ["return"]}        the document, and Return added a line)
```

Nor this, asked for `Close`:

```
eyes read {"window": 263}
                  -> 472,95	Close All	pixels
vhid press {"chords": ["down"]}         (the row starts with the name but is
vhid press {"chords": ["return"]}        another item: every window closed)
```

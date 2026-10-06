---
name: menu-item
description: Invoke any app's menu item by its name on this Mac through its real keyboard and mouse - open the app's Help menu with vhid, search for the item, read the results with eyes, and choose it; or click down the menu path for items in the Help menu itself. Use when the user asks for a menu command, especially one with no shortcut ("choose File > Export as PDF in TextEdit", "use the Customize Toolbar menu item in Finder", "open Chrome's Task Manager from the Window menu", "invoke a menu command that has no shortcut"), or names a menu item in any app, in any language.
---

# Invoke a menu item by its name

The route is Help search: click the app's Help title, type the item's name or its
start, read the "Menu Items" rows, then Down and Return. It finds an item at any depth
without knowing its path, and lists items that appear only with Option held. Help
search does not search the Help menu itself, so an item there is clicked down its path.

Every step below is a look before an act; the look-click-look skill has the loop,
the before-you-type check, the `until`/`timeout` wait and what to do when a tool
refuses. One thing more than it says: eyes reads menus by pixels only. "…" reads as
"...", case drifts ("Go" reads "GO"), and a menu bar can read as one run. Never `find`
an item's full title with `exact`. Search with its name or its start; judge a row
against the whole name, loosely.

Not App Shortcuts, not `defaults write`, not `osascript` clicking menus: a shortcut
stays in the user's keyboard settings and rebinds the item for them too, and the
others reach around the devices.

## Help search

1. **Front.** `windows` - the app's rows are marked `front`. Check the rows, not the
   header: its "Frontmost:" name can differ from the owner ("Code" for "Visual
   Studio Code"). An app with no windows listed is in front when the header's
   Frontmost names it. If the app is not in front, click one of its visible windows
   on the title bar, not content that could act, or its Dock icon found with
   `find`; then `windows` again, three looks in all, until its rows are `front`. Not
   `open -a`, not `osascript`.
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
   app on layer 101. It can come late - TextEdit's showed on the second look - so look
   three times in all before calling the click a miss. Then `read` that window: the
   Help menu reads "Search", its search field (TextEdit: `433,41 Search`, `452,69
   TextEdit Help`). No "Search": the click opened another menu - escape until its
   window is gone, one press per look, and find and click the title once more. No
   layer-101 window, or not the Help menu: do not type. A keystroke sent when the
   menu did not open lands in the document behind it.
4. **Type the name, or its start,** as the app shows it, in the app's language
   ("Exporter au format PDF" in a French TextEdit), without its ellipsis:
   `type {"text": "Export as PDF"}`. Do not open search with ⇧⌘/: TextEdit's own Help
   took that key instead. The search field opens empty or holding the last query,
   selected; your typing replaces it.
5. **Read the results:** `read {"window": <id>}` the layer-101 window, by id each
   time: it keeps its id and grows as results come in. Rows are point, box, text, role,
   and you compare the text. No "Menu Items" or "Help Topics" heading yet, and no "No
   Results Found": the results are not in - read again. Down takes the first row under
   "Menu Items" (above "Help Topics"), whatever it is. That row must be the whole
   name, compared loosely: "..." for "…", drifted case, and a stray glyph before
   the name, which is the item's icon (TextEdit read `EJ Export as PDF...`). An item
   in a top-level menu shows no path (Chrome's Window > Task Manager reads `Task
   Manager`); only a submenu item does ("New Window with Profile > New
   Profile..."), and there you judge the text after the last " > ". The name plus
   more words is another item: `Close All` is not `Close`. If the first row is not
   the item, the list may still be the last search's: read again. Three reads in all
   after typing, counting the reads that waited for results, no more. Still not
   first: type the next words of the name - they append to what is in the field - and
   read the same way. Still not first: escape until the layer-101 window is gone, one
   press per look, as in "No item matches", then take the path route.
6. **Choose it:** `press {"chords": ["down"]}`, then `press {"chords": ["return"]}`.
7. **Look for what it does.** An item that opens a window or sheet: `windows` for
   it - TextEdit's export sheet came back as a new window. The first look can still
   show leftover menus on layer 101 (and a layer-1000 window); look again, three
   looks in all - an early look is not "nothing happened", nor a reason to run the
   item again. Then wait inside it: `find` text only that item's result has, with
   `"window": <new id>`, `until` `present` and a `timeout`. Not "Save", not the
   window's size: a plain Save sheet of the same document is as large and has "Save
   As:", "Cancel" and "Save" too, but no "Show Details", which the export sheet has.
   An item that opens no window (a checkmark toggled, a panel shown or hidden): the
   change is in the window it acts on, the front document window - `read` it, and
   wait for the changed text there with `find`, `until` and a `timeout`.
   Done means you saw it.

   Nothing by the third look or the timeout: `windows`. A layer-101 window still
   there then means the item did not run - often disabled, which Help search still
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
Path unknown: open the app's menu titles in turn, each once - click, look, `read`,
escape until its window is gone - until one lists the item's menu or the item.

## Shape of a run

```
eyes windows      -> ... Frontmost: TextEdit (pid N), its rows marked front.
eyes find {"text": "Help", "rect": "0,0,800,30"}
                  -> (a scope line, then) 422,14	406,7,32,15	Help	pixels
vhid click {"x": 422, "y": 14}
eyes windows      -> no layer-101 window yet: look again
eyes windows      -> 180	TextEdit	L101	395,25 360x59	front    a menu is open
eyes read {"window": 180}
                  -> 433,41	410,33,46,16	Search	pixels
                     452,69	410,61,84,16	TextEdit Help	pixels           "Search": the Help menu
vhid type {"text": "Export as PDF"}
eyes read {"window": 180}
                  -> Search, TextEdit Help only, still 59 high, no heading:
                     not in yet
eyes read {"window": 180}
                  -> 457,40	410,32,94,16	Export as PDF	pixels
                     444,73	410,66,68,14	Menu Items	pixels
                     472,95	412,87,120,16	EJ Export as PDF...	pixels      first row, the whole name: this one
                     445,116	410,109,70,14	Help Topics	pixels
eyes windows      -> 180	TextEdit	L101	395,25 360x151	front   same id, grown
vhid press {"chords": ["down"]}
vhid press {"chords": ["return"]}
eyes windows      -> leftover layer-101 menus, no new window: look again
eyes windows      -> 189	TextEdit	L0	501,125 800x448	front    a new window
eyes find {"text": "Show Details", "window": 189, "until": "present", "timeout": 5}
                  -> a Show Details row at 816,543, which a plain Save sheet
                     lacks: the export sheet: invoked
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
eyes read {"window": 180}
                  -> 472,95	440,87,64,16	Close All	pixels
vhid press {"chords": ["down"]}         (the row starts with the name but is
vhid press {"chords": ["return"]}        another item: every window closed)
```

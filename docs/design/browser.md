# Web pages: what eyes finds

An agent clicks a web element by finding its text with `eyes find` and clicking the point with `vhid click`. This note records how far that gets in Safari, Chrome and Firefox today, and where it fails. None of it needs a browser extension or a DevTools connection. `eyes read` runs the same readers over the same region and lists every run `find` chooses among ([Find.swift](../../eyes/Sources/Command/Find.swift)), so what holds for `find` here holds for `read`.

Measured on studious on 2026-10-03: macOS 15.0.1, Safari 18.0.1, Chrome 154.0.8037.58, Firefox 157.0, eyes and vhid 0.2.0 (eyes' sources are unchanged since). Each element was checked by clicking the merged answer's point with `vhid click`. The page reports which element took the click.

## The decisions

- **No browser-side piece.** Every element the page offered was found at the right point by one reader or the other, once it was on screen. Nothing measured needs a DevTools connection or an extension, so neither clears [the scope bar](../development.md#scope).
- **The gaps are in what `eyes` reports, not in what it sees.** It reports a Chrome element that is off screen as on screen. It does not say a row's role, so a page button and a browser button with the same name look the same. And it cannot tell apart three buttons that share one label.
- **Reaching an element below the fold is vhid's job, and vhid's wheel is broken.** `vhid scroll` packs up to 127 ticks into one wheel event, so in Safari a call barely moves the page (vhid-scroll-1m8). Firefox moves much further per event, so many calls get there. In Firefox the End key reached the bottom at once.

## What eyes does about it

The gaps below were measured with eyes 0.2.0. The next release closes the ones that are eyes' own. Each element was checked on the probe page in Safari and Chrome, and spot-checked in Firefox, by clicking the point `eyes find --page` gave with `vhid click`.

- **Off-screen elements.** Chrome places an element scrolled wholly out of view as a strip one point thick on the viewport's nearest edge: "Far below" read as 96x1 at y=877, the page's last row. The tree reader drops any frame no more than a point across as unplaced (`isThin` in [Walk.swift](../../eyes/Sources/Tree/Walk.swift)), so with the page at the top Chrome now answers "not found", as Safari and Firefox do.
- **Roles.** Every row prints the element's role, or `pixels` for text only pixels saw.
- **The page apart from the browser.** `--page <window id>` reads the window's `AXWebArea` and nothing around it. In Chrome, "Settings" in the page alone is the page's button, not the "Settings, opens in new tab" bookmark.
- **Repeated labels.** `--near <text>` puts the match closest to that text first: nearest across lines, then along the line, and on a tie the match that comes after the text. The tie rule is for Safari, which reads " · Pricing " as one run touching both "More" links.

## What was found

Each cell names the readers that found the element. "Right" means a click on the merged answer's point landed on that element. For the canvas, the page could only tell that the click landed on the canvas, not on the word.

| Element | Safari | Chrome | Firefox |
| --- | --- | --- | --- |
| Text button ("Send report") | right, tree and pixels | right, tree and pixels | right, tree and pixels |
| Link ("Read the changelog") | right, tree and pixels; the tree lists it twice | right, tree and pixels | right, tree and pixels |
| Two links both reading "More" | both right; the tree lists each twice | both right | both right |
| Icon-only button, `aria-label="Settings"` | right, tree only | right, tree only, but a bookmark named "Settings, opens in new tab" is listed first | right, tree only |
| Text field by its `<label>` ("Email address") | right: the label and the field both match, and a click on either reaches the field | right, same | right, same |
| Three "Remove" buttons, one per row | three right points, nothing to tell them apart | same | same |
| Button in an iframe ("Inside frame") | right, tree and pixels | right, tree and pixels | right, tree and pixels |
| Text drawn on a canvas ("Canvas word") | on the canvas, pixels only | on the canvas, pixels only | on the canvas, pixels only |
| Button 3000 points below the fold ("Far below") | not found; found and right after scrolling | **found at a wrong point**: the tree places it on the viewport's bottom edge, and a click there misses the button; right after scrolling | not found; found and right after the End key |

The tree reads `aria-label` (the button's accessibility description), iframe content and labelled fields in all three browsers. Pixels covers canvas text, which has no tree node. The default merged reader found every on-screen element at the right point, though in Chrome its first "Settings" row was the bookmark's.

## The gaps

**Chrome reports off-screen elements as on screen.** With the page at the top, `eyes find "Far below" --source tree` in Chrome answered `100,878`, the bottom edge of a window whose content ends at y=878, while the button sat about 3000 points further down. Pixels did not find it. In Safari and Firefox the same search answers "not found", which is true. So in Chrome a below-the-fold element is a confident match at a point that misses it. This is the one result that is wrong, not missing, and it breaks the checkpoint of vhid-browser-j5d: each click lands on the element meant, never its look-alike.

**Rows carry no role, so look-alikes cannot be told apart.** `eyes find` and its MCP tool print a point and a text, nothing else, although the tree reader holds each element's role (`Found.source` is `.tree(role:)`). Three things followed on the probe page:

- "Settings" in Chrome matched the browser's bookmark bar before the page's button, and clicking the first match opened Chrome's settings in a new tab. A whole-window search reaches the browser's own toolbar and bookmarks as well as the page.
- "Email address" returns the label and the field as two rows of the same text. That worked here, because a click on a label is passed to its field, but nothing tells the agent which row is the field.
- Safari's tree lists a link and the text inside it as two rows at one point.

**Repeated labels have only their position.** The three "Remove" buttons come back as three points in reading order. "The Remove in Beta's row" means matching each point's y to the row text's y, which an agent can do but `eyes` does not.

**Below the fold needs scrolling, and vhid's wheel falls short in Safari.** In Safari, `vhid scroll 800 600 --vertical 100` moved the page 13 points, while twenty `--vertical 1` calls moved it more than 500 (vhid-scroll-1m8). Firefox moves 230 to 300 points per `--vertical 5` call. A first run on the probe page seemed to stall partway. A rerun on a separate page that shows its scroll position and counts wheel events found no stall: each of 180 `--vertical 5` calls reached the page as one wheel event, and the page hit bottom before call 80 (vhid-browser-j5d.dap). Once the element was on screen, all three browsers found it at the right point.

## Repeating it

The probe page, [browser-probe.html](browser-probe.html), holds one of each element above, and a fixed status line at the top that numbers each click, names the element it landed on (`none` for a miss), and names the focused element. Open it from disk in each browser on studious. For each element's text, run `eyes find "<text>" --window <id>` once per `--source`. Then `vhid click` the merged answer's point and read the status line with `eyes find "Last click" --window <id> --source tree`. Pass `--page <id>` in place of `--window <id>` for the page's own match, not the bookmark bar's.

Three traps cost time here. A `find` that matches nothing still prints the nearest runs as rows, so a script that clicks "the second line" clicks a near miss, such as the browser's Reload button. A scroll or click goes to whatever window is on top at the point, so with another app's window over it a scroll reaches nothing and looks like a browser that stopped scrolling. And studious is shared: another session's input can take focus mid-run, which showed up as a covered window and clicks reporting the element before.

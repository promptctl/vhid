# eyes: reading the screen

`eyes` says what is on screen and where, in the coordinates `vhid click` takes. `eyes help <verb>` has each verb's full text.

```sh
eyes windows                      # owner, layer and bounds of each on-screen window; the frontmost app
eyes displays                     # each display's id, bounds and scale, main first
eyes find Save                    # where "Save" is: the point to click, its box, then the text
eyes find Settings --exact --display 3
eyes read --window 4127           # every run of text in one window, in reading order
eyes find OK --source tree        # only the accessibility tree: exact text, no Screen Recording
eyes find Saving --window 4127 --until absent --timeout 30   # returns once the text is gone
eyes find Settings --page 219     # only the web page in browser window 219, not its toolbar or bookmarks
eyes find Remove --near Beta      # every "Remove", the one beside "Beta" first
eyes hit 169 426                  # what a click at 169,426 lands on: the app, its window, the element
eyes grants                       # Screen Recording and Accessibility: held or not, and the app they are charged to
eyes grants --ask                 # raise macOS's dialog for each missing grant (once per app); run eyes grants again once answered
eyes mcp                          # the verbs as MCP tools over stdio: windows, displays, find, read, hit, grants
```

`find` and `read` read with `--source`: `tree` walks the accessibility tree (exact text
and roles; needs Accessibility), `pixels` recognises text on-device with Vision (anything
drawn; needs Screen Recording), and `merged`, the default, asks both and reports a thing
both saw once. A merge with one grant missing still answers from the other and says which
reader could not look. Each prints a scope line first — where it looked, which reader
looked, how many runs it read, what it set aside, whether it read the whole region. A `find` that matches nothing prints the nearest runs
and how many edits off each is, so a misread one edit away is not taken for an absence.

Named no place, `find` and `read` read what is in front: the frontmost app's windows
and whatever is over its front window, such as an Open panel another process draws, on
the display holding that window. When the frontmost app is the one eyes answers to — the
terminal or app running it, which shows the very text an agent asks eyes to find — they
read the app behind it instead and say they passed it over; that app's windows are never
read, in front or not. A window over the front one is read only where the system's hit
test lands a click in it, so a full-screen overlay that draws nothing there is not. Text
in a window behind is not read, and the pixels reader counts it as `outside`; text under
a window in front where a click lands elsewhere is `covered`, and where the hit test does
not answer, as without Accessibility, `overlaid` and the region is not read whole. The
menu bar is not read either, since `--rect` reads it. With nothing but that app on screen,
the look is refused. `--display` reads every app on a display.

Each row is a point, the box around the run, the text, and what it is: the role the
accessibility tree gives the element (`AXButton`, `AXLink`, `AXTextField`, ...), or
`pixels` for text only the pixels reader saw, such as words drawn on a canvas. The role
is what tells a page's Settings button from a browser bookmark of the same name, or a
field from its label. The box is `x,y,width,height` in the same points, the form `--rect`
takes, rounded outward to whole points so it covers the run and holds the point printed
beside it. Every rectangle eyes prints is in that form, a window's or display's bounds and
a scope line's region too, so any of them can be passed back as `--rect`.

A row the accessibility tree found has its box checked against where a click lands. An
element's frame is its app's claim: Safari gives a page's native-looking button a frame
several points wider than the button, and a click inside the frame can press the page
beside it. So eyes asks the system's hit test, which is what routes a click, outward from
the row's point along the lines through it, and cuts each edge in to the last point a click
still presses the element; then along the diagonals to the box's corners, drawing its sides
in where a rounded button's corner presses the page. The checks get two seconds on top of
the read. The scope line says how many boxes were cut, and how many were left as the app
claimed them and why: the hit test did not answer, the row's own point lands on something
else, or the time ran out. Text only the pixels reader saw keeps the box its text is drawn
in. A wait checks only the boxes of the reading it ends on, in what is left of its timeout.

`--page <window id>` reads the web page a browser window shows, without the browser's
toolbar and bookmarks. The accessibility tree finds the page, so it needs Accessibility
even with `--source pixels`. A window showing no page, or two side by side such as a page
and a docked DevTools, is refused; read one of the two with `--rect`.

`--near <text>` orders the matches by how close each sits to a run containing that text,
on the same line first: of three "Remove" buttons, the one in Beta's row comes first, and
`--limit 1` leaves only it. When nothing on screen contains the `--near` text, no match
is answered, since which one was meant is unknown: the scope line names that text as not
found, the rows are its near misses, and a wait settles neither present nor absent on it.

`hit X Y` asks the system's hit test what a click at that point, as `vhid click X Y` takes
it, would land on, and says so before anything is pressed. Its first line names the app,
whether a look with no place named reads it - the front app, a window over it such as an
Open panel, the app eyes answers to, or an app behind - and its window by the id `--window`
takes. Then a row per element: the one hit, then each holding it, up to the area that holds
them, such as a window, a list, a toolbar or a web page, each with its role, its frame and
what it says. A click on a button's label lands on the label; the row under it is the
button. It needs Accessibility, and decides nothing: `vhid click` presses what is there
whatever it said. The hit tests get the same two seconds as a look's box checks, and a
climb they do not finish says where it stopped and why.

`find --until present|absent` re-reads the same rectangle until the text appears or is
gone, then answers once, its scope line led by how many reads it took and how long. A
window that closes counts as gone. Absent needs two whole reads running without a match.
A reader that cannot look ends the wait with its error rather than reporting "gone".
When `--timeout` runs out, the answer is the last reading, marked as timed out.

## Events

Every look (`find`, `read`, and each wait), every `hit`, every grant check a reader makes, and every
grants reading taken from a child emits one JSON event, from the verbs and the tools alike. Events go to the OTLP collector that
`OTEL_EXPORTER_OTLP_ENDPOINT` names. With no collector set, or one that can't take them,
they're appended to `~/Library/Logs/eyes/events.jsonl`. An event appended because the
collector failed carries `sink_error`.

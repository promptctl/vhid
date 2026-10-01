# eyes: reading the screen

`eyes` says what is on screen and where, in the coordinates `vhid click` takes. `eyes help <verb>` has each verb's full text.

```sh
eyes windows                      # owner, layer and bounds of each on-screen window; the frontmost app
eyes displays                     # each display's id, bounds and scale, main first
eyes find Save                    # where "Save" is: the point to click, then the text
eyes find Settings --exact --display 3
eyes read --window 4127           # every run of text in one window, in reading order
eyes find OK --source tree        # only the accessibility tree: exact text, no Screen Recording
eyes find Saving --window 4127 --until absent --timeout 30   # returns once the text is gone
eyes grants                       # Screen Recording and Accessibility: held or not, and the app they are charged to
eyes grants --ask                 # raise macOS's dialog for each missing grant (once per app); run eyes grants again once answered
eyes mcp                          # the verbs as MCP tools over stdio: windows, displays, find, read, grants
```

`find` and `read` read with `--source`: `tree` walks the accessibility tree (exact text
and roles; needs Accessibility), `pixels` recognises text on-device with Vision (anything
drawn; needs Screen Recording), and `merged`, the default, asks both and reports a thing
both saw once. A merge with one grant missing still answers from the other and says which
reader could not look. Each prints a scope line first — where it looked, which reader
looked, how many runs it read, what it set aside, whether it read the whole region. A `find` that matches nothing prints the nearest runs
and how many edits off each is, so a misread one edit away is not taken for an absence.

`find --until present|absent` re-reads the same rectangle until the text appears or is
gone, then answers once, its scope line led by how many reads it took and how long. A
window that closes counts as gone. Absent needs two whole reads running without a match.
A reader that cannot look ends the wait with its error rather than reporting "gone".
When `--timeout` runs out, the answer is the last reading, marked as timed out.

## Events

Every look (`find`, `read`, and each wait), every grant check a reader makes, and every
grants reading taken from a child emits one JSON event, from the verbs and the tools alike. Events go to the OTLP collector that
`OTEL_EXPORTER_OTLP_ENDPOINT` names. With no collector set, or one that can't take them,
they're appended to `~/Library/Logs/eyes/events.jsonl`. An event appended because the
collector failed carries `sink_error`.

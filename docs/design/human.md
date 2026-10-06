# Human hands: design

What vhid's pointer, clicks and typing look like to a web page today, what a person's look like, and the model `move`, `click`, `drag`, `scroll`, `type` and `press` will follow to close the gap. `vhid play` replays a script's own timing and is not covered here.

Measured on studious on 2026-10-06: macOS 15.0.1, Safari 18.0.1, vhid 0.4.1, the virtual pointer at the system's default tracking speed (`com.apple.mouse.scaling` 2). The human figures come from the literature cited beside each one.

## The decisions

- **A move takes as long as a person's would, by Fitts' law:** 50 ms + 150 ms × log2(D/20 + 1), D in points, varied by ±15% (one standard deviation). That is about 0.84 s across 740 points and 0.44 s across 100.
- **The path is a person's:** a main movement with a bell-shaped speed profile (minimum jerk) that bows slightly to one side and stops short, then a short correction onto the target. Reports go out every 8 ms, the rate of a 125 Hz USB mouse.
- **The path is steered by reading the cursor back once a tick**, not from a table calibrated beforehand. The cursor reflects a report about a millisecond after it is sent, so each report can be aimed from where the last one actually landed, and the acceleration curve is learned from the reports as they land.
- **The end point is today's.** The path ends with the closed loop `Pointer.move(to:)` ran in 0.4.1, now `Pointer.home(on:)`, with its reports paced at the same 8 ms, so a click lands where it landed.
- **A click rests, then holds:** a pause on the target before the button goes down (250 ± 80 ms), then the button held for 110 ± 30 ms. The clicks of a double or triple click are 120 ± 30 ms apart, one press at most 380 ms after the last, inside macOS's double-click interval.
- **A scroll rests, then turns the wheel:** the same move and rest as a click, then notches 230 ± 20 ms apart, never closer than today's 200 ms.
- **Typing has a typist's rhythm:** 180 ± 60 ms from one key-down to the next (about 67 words a minute), each key held 95 ± 25 ms, and Shift and other modifiers down 30–80 ms before their key and up 20–60 ms after it, held through a run of keys that all need them and never down on a key that does not.
- **Every pause is drawn from a seeded random number generator.** The CLI and the MCP server seed it from the system; a test passes a fixed seed and a test clock and checks exact times.
- **This is how the verbs behave, with no option to turn it off.** The cost is time: a click now takes about a second, and 1,000 characters take about three minutes to type.

All "± x" figures are a normal distribution's mean and standard deviation. A draw outside the floors and ceilings below is drawn again, never clamped: clamping would pile identical values at each bound, the uniform timing this design removes.

## vhid today

A probe page ([human-probe.html](human-probe.html), served by [human-probe.py](human-probe.py)) logged every pointer and key event Safari dispatched while `vhid move`, `vhid click` and `vhid type` ran against it.

| What | vhid 0.4.1 | A person |
| --- | --- | --- |
| A 740-point move | 30–45 ms, as 3–4 pointer events; the first jumps about 250–300 points | about 0.8 s by Fitts' law [1]; no jump over 100 points |
| Button down to up | about 1 ms; a double click's two clicks 13 ms apart | 110 ± 30 ms [1] |
| Key down to next key down | median 2 ms; 53 characters in 1.3 s | 180 ± 60 ms [1] |
| Key held | median 1 ms, at most 17 | 80–120 ms (assumed; see below) |

Every vhid click is a *teleport click* as the bot-detection literature defines it: a cursor jump of more than 100 px in under 50 ms within 100 ms before the click [1]. That paper finds two features enough to catch every agent it tested: the ratio of teleport clicks and the rate of mouse events a page sees. vhid's 8 ms reports reach a page as about one pointer event a frame, as a 125 Hz mouse's do; what gives it away today is that a move is three or four of them.

## The model

### How long a move takes

Fitts' law, with the constants [1] uses for its human-like generator: MT = 50 ms + 150 ms × log2(D/W + 1). vhid is given a point, not a target, so W is fixed at 20 points, about the height of a button or a line of text. MT is multiplied by a factor drawn from N(1, 0.15), cut off to 0.7–1.3, so two moves over the same distance do not take the same time. A move under a point long takes no time and is just the closing loop.

### The path

A person's aimed movement is a main movement that gets most of the way, then one or more small corrections [2]. Each movement's speed rises and falls in a bell shape, which is what minimising jerk produces [3]:

- **Main movement:** 80% of MT, aimed at a point short of the target by N(5%, 3%) of D, cut off to 1–10%, and off the line by N(0, 2%) of D, cut off to ±4%. Its path bows to one side by N(0, 3%) of D at the middle, cut off to ±6%. At fraction τ of its time it has covered u = 10τ³ − 15τ⁴ + 6τ⁵ of its distance (the minimum-jerk curve), and sits that bow × sin(π u) off the straight line.
- **Correction:** the remaining 20% of MT, a minimum-jerk straight line from wherever the main movement ended to the target.
- **Closing:** `Pointer.home(on:)`'s loop, its reports paced 8 ms apart, for the last fraction of a point the steered path leaves.

There is no added tremor. Rounding each report to whole counts already makes the step lengths uneven.

**The path stays on the displays.** The bow and the aim off the line are drawn in full, then scaled down together to the largest of 100%, 90%, … 10% that keeps every point of the path at least as far from the displays' edges as the straight line is at that moment, up to 20 points; if no share fits, the path is the straight line. Without this, a target beside an edge, approached along it, sends the path into the edge mid-move. The display layout is read by vhidd in the session in front, as the cursor is. It reads the online displays, not the active ones, because a display that is asleep is not active but the cursor still moves on it. On studious, 20 clicks 10 points from the edge holding its auto-hidden Dock, each approached along that edge, never raised the Dock. Each move records the share it kept as `bow_kept` and the layout it was kept on as `displays`, so the seed and the layout draw its path again.

### Steering the path

Each 8 ms tick asks where the path should be at that tick's deadline, reads where the cursor is, and sends the report the acceleration curve learned so far says covers the difference. The deadlines are measured from the start of the move, so a late report is followed by a larger one rather than pushing the rest of the path back.

Three things differ from `Pointer.home(on:)`, the closed loop. A tick reads the cursor once, at its deadline, and does not wait for it to move: `home` waits up to 50 ms, six ticks. A report the cursor has not yet shown is distance already covered, not distance to send again: a tick aims from the cursor as read plus the expected motion of every report still unseen. When the cursor does move, the change is matched to the oldest unseen reports whose expected motion sums closest to it; those are seen, the rest stay unseen, and one unseen for longer than 50 ms moved nothing. And what is learned is a curve, not one gain. `home` caps each report at the length of the one its gain was read from (`Pointer.Gain.upTo`), because macOS moves a fast report further per count than a slow one; a path that speeds up needs each report longer than the last, so steering learns points per count by report length from the reports the cursor has shown, interpolates between them as `vhid play`'s table does, and past the longest carries the slope of the last two on.

That was not the first design. One gain read off the last report, uncapped, was reasoned to cost a tick's worth of error that the next tick takes back. On a fake curve shaped like the measured one (0.3, 0.6 and 0.75 points a count at two, four and five counts, where `Pointer.Gain` and the paragraph below measured 0.25, 0.59 and 0.87) the error grew instead: a long report thrown far, a short one learned from that, then a longer one, until the cursor was 260 points off its path mid-move. Holding the longest length's gain for longer reports failed the same way more slowly: a gain too low throws the report long, and it misleads the match too, since the change then looks like more of the unseen reports than it is. So a longer report is asked at a gain that errs high, which only shortens it, and a report is at most twice as long as the longest the cursor has shown, plus a count so a diagonal's rounding can reach past it. `SteeringTheTrajectoryTests` holds the cursor within 6 points of the path a tick behind it, over ten seeds and four moves, and with one report in four shown a tick late never past the target.

The closing loop starts once every report the path sent has shown or been given up on, so it starts from where the cursor is. It keeps `home`'s cap and its wait, because its job is to land, not to keep time.

This works because the cursor moves soon after a report. [human-cursor-poll.swift](human-cursor-poll.swift) printed every change of the cursor's location while `vhid play` sent 40 reports of 5 counts, 20 of them 8 ms apart and 20 of them 16 ms apart. Each report moved the cursor exactly once, by 4.35 points every time at both paces. The cursor moved a median of 1.3 ms after the report was sent; 36 of 40 moved within 4.2 ms, and the slowest within 22 ms. A read at the next tick, 8 ms after the report, therefore sees it nine times in ten. The rest show up a tick or two late, which is why unseen reports are counted as covered: sending their distance again would overshoot by a tick's worth and then turn back mid-move. A cursor that showed every report late could not be steered this way: while the curve is being learned, two reports shown together read exactly as one report on a curve twice as steep.

`vhid play`'s calibrated table was the other option. It was ruled out because the calibration is itself motion: bursts of up to 127 counts back and forth before the move starts, which looks nothing like a person, and it would run on every call because each `vhid` call is a new process.

### Clicks

- **Rest on the target before pressing:** N(250, 80) ms, cut off to 120–500 ms. People do pause before they press, and some web menus need hover: on 2026-10-03 a bare `vhid click` on an item in GitHub's repository picker selected nothing three times, while moving, waiting 0.8 s and clicking selected it first time. On 2026-10-06 that picker sat behind GitHub's sudo-mode 2FA, so it was not tried again. GitHub's repository Type filter and branch picker take a click with no rest. On a local menu that takes a click only after the pointer has rested on an item for 100 ms, as hover-intent menus do, vhid 0.2.0 was ignored 3 times out of 3 and a click with this rest selected 3 times out of 3.
- **Hold the button:** N(110, 30) ms, cut off to 60–200 ms [1].
- **Between the clicks of a double or triple click:** N(120, 30) ms from up to down, cut off to 60–180 ms. With holds of at most 200 ms, each press comes at most 380 ms after the one before, inside macOS's default double-click interval of 0.5 s, which both test Macs keep. On a Mac set shorter, read from `NSEvent.doubleClickInterval`, which answers IOHIDSystem's one `HIDClickTime` in any process and so is the interval of the session in front, whoever's it is, the hold and the gap are scaled down together until each press comes within 80% of it, but no lower than their 60 ms floors; on a Mac set below the 150 ms macOS's settings allow, as `defaults write -g com.apple.mouse.doubleClickThreshold` can from the next login, where two floors would not fit, the floor is half the 80%, so a double click is still one.
- **A drag** rests on the start point as a click does, holds the button N(100, 25) ms, cut off to 50–200 ms, before carrying it, and rests the same on the end point before letting go.

### Scrolling

`scroll` moves to its point by the path above and rests there as a click does, N(250, 80) ms, before the first notch. Notches are drawn from N(230, 20) ms and cut off to 200–300 ms, so they do not tick like a metronome. The floor is `Hand.notch`'s 200 ms, chosen a third clear of the 150 ms below which its measurements show Safari and TextEdit accelerating notches, so `--vertical N` still scrolls N times as far as `--vertical 1`. No source here measures wheel timing; this keeps today's pace and varies it.

### Typing

- **From one key-down to the next:** N(180, 60) ms, cut off to 70 ms at the low end [1]. That is about 67 words a minute, a practised typist's speed.
- **Each key held:** N(95, 25) ms, cut off to 40–200 ms, and to 80% of the Mac's delay until a held key repeats where that is lower: `defaults write -g InitialKeyRepeat` can set it under System Settings' shortest, 225 ms, from the next login, which is when a user's setting reaches the HID system. Below 250 ms the whole distribution shrinks with it, so neither a long draw nor a key-up sent late behind a slow acknowledgement types a character twice. The hold is drawn before the gap is placed and is never shortened to fit it. No source here measures key holds; 80–120 ms is the range commonly given for them, and it was not checked.
- **Modifiers:** a Shift, Option, Control or Command a keystroke needs goes down 30–80 ms before the key and comes up 20–60 ms after it. One the next keystroke also needs stays down between them, as a person holds Shift through a capitalised word. One the next keystroke does not need is up before that keystroke's modifiers or key go down.
- **Fitting it together:** the next keystroke's first event, its first new modifier going down or else its key, comes at least 20 ms after this key is up and after the modifiers it does not share are up. Its key goes down at the drawn gap or at that first event plus its drawn lead, whichever is later. So keys never overlap, and a modifier is never down on a key that did not ask for it.
- **A chord** (`vhid press`) uses the same modifier lead and key hold, and lets go of its modifiers before the next chord: each chord is a whole act, so `leftCommand+tab leftCommand+tab` is two app switches, not a Command held through both.
- **No typos.** Text that is typed wrong and then corrected is not what a caller asked for.

A character typed as a dead key and then a letter is two keystrokes, and each gets its own gap.

## Sources

1. V. Choudhary et al., "What Does It Take to Detect an AI Agent? Minimal Feature Sets for Behavioral Detection under Browser Automation", arXiv:2607.26935, 2026. Appendix B (click duration, typing speed, teleportation, teleport-click ratio) and Appendix D (the Fitts constants, click holds N(110, 30) ms and key gaps N(180, 60) ms, which it takes as human distributions).
2. D. E. Meyer et al., "Optimality in human motor performance: ideal control of rapid aimed movements", Psychological Review 95(3):340–370, 1988.
3. T. Flash and N. Hogan, "The coordination of arm movements: an experimentally confirmed mathematical model", Journal of Neuroscience 5(7):1688–1703, 1985.

## Repeating it

**The page.** Copy `human-probe.html` and `human-probe.py` to the Mac, run `python3 human-probe.py` in a scratch directory, and open `http://localhost:8765/` in Safari. Find the buttons with `eyes find "Target A"`, then run the verbs against them. The page posts what it saw every half second, and the server appends it to `events.jsonl`, one event a line with the page's own millisecond timestamp. Split pointer events into moves at gaps of more than 300 ms. A move's distance is in screen points from where the cursor rested to the button; the first event a page sees comes after the first jump, so it is not the start. The page sees what the browser dispatches, about one pointer event a frame, so it understates the event rate of a move that runs longer than a frame.

**The HID system's timings.** Build `human-hid-params.swift` with `swiftc -O`. Run as any user, it prints `NSEvent`'s double-click interval and delay until a held key repeats, in seconds; run as root with a key and nanoseconds, `HIDClickTime 900000000`, it first sets that IOHIDSystem parameter. On studious (macOS 15.0.1), 2026-10-06, setting `HIDClickTime` to 0.9 s or `HIDInitialKeyRepeat` to 0.3 s moved what it printed both as bmf, logged in at the screen, and as bbb, who had no session; bmf's `defaults write -g com.apple.mouse.doubleClickThreshold 1.5` and `InitialKeyRepeat 15` moved neither. Note what it prints before setting anything, and set both back to that after.

**The cursor.** Build `human-cursor-poll.swift` with `swiftc -O`, start it for 4 seconds as the user logged in at the screen, and while it runs `vhid play` a script of `move` lines whose start line is the cursor's current point, so play sends no approach reports before its clock starts. Pair the n-th change it prints with the n-th report `vhid play` prints; each line of `vhid play` carries the report's `sent_us` and `acked_us` on the same clock.

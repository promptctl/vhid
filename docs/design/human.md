# Human hands: design

What vhid's pointer, clicks and typing look like to a web page today, what a person's look like, and the model `move`, `click`, `drag`, `scroll`, `type` and `press` will follow to close the gap. `vhid play` replays a script's own timing and is not covered here.

Measured on studious on 2026-10-06: macOS 15.0.1, Safari 18.0.1, vhid 0.4.1, the virtual pointer at the system's default tracking speed (`com.apple.mouse.scaling` 2). The human figures come from the literature cited beside each one.

## The decisions

- **A move takes as long as a person's would, by Fitts' law:** 50 ms + 150 ms × log2(D/20 + 1), D in points, varied by ±15% (one standard deviation). That is about 0.84 s across 740 points and 0.44 s across 100.
- **The path is a person's:** a main movement with a bell-shaped speed profile (minimum jerk) that bows slightly to one side and stops short, then a short correction onto the target. Reports go out every 8 ms, the rate of a 125 Hz USB mouse.
- **The path is steered by reading the cursor back after every report**, not from a table calibrated beforehand. The cursor reflects a report about a millisecond after it is sent, so each report can be aimed from where the last one actually landed.
- **The end point is exact.** The path ends with the closed loop `Pointer.move(to:)` runs now, with its reports paced at the same 8 ms, so a click lands where it lands today.
- **A click rests, then holds:** a pause on the target before the button goes down (250 ± 80 ms), then the button held for 110 ± 30 ms. The clicks of a double or triple click are 120 ± 30 ms apart, always inside macOS's double-click interval.
- **Typing has a typist's rhythm:** 180 ± 60 ms from one key-down to the next (about 67 words a minute), each key held 95 ± 25 ms, and Shift and other modifiers down 30–80 ms before their key and up 20–60 ms after it.
- **Every pause is drawn from a seeded random number generator.** The CLI and the MCP server seed it from the system; a test passes a fixed seed and a test clock and checks exact times.
- **This is how the verbs behave, with no option to turn it off.** The cost is time: a click now takes about a second, and 1,000 characters take about three minutes to type.

All "± x" figures are a normal distribution's mean and standard deviation, cut off at the floors and ceilings below.

## vhid today

A probe page ([human-probe.html](human-probe.html), served by [human-probe.py](human-probe.py)) logged every pointer and key event Safari dispatched while `vhid move`, `vhid click` and `vhid type` ran against it.

| What | vhid 0.4.1 | A person |
| --- | --- | --- |
| A 740-point move | 30–45 ms, as 3–4 pointer events; the first jumps about 250–300 points | about 0.8 s by Fitts' law [1]; no jump over 100 points |
| Button down to up | about 1 ms; a double click's two clicks 13 ms apart | 110 ± 30 ms [1] |
| Key down to next key down | median 2 ms; 53 characters in 1.3 s | 180 ± 60 ms [1] |
| Key held | median 1 ms, at most 17 | 80–120 ms (assumed; see below) |

Every vhid click is a *teleport click* as the bot-detection literature defines it: a cursor jump of more than 100 px in under 50 ms within 100 ms before the click [1]. That signature, together with click durations under 10 ms, is how that paper separates automation from people.

## The model

### How long a move takes

Fitts' law, with the constants [1] uses for its human-like generator: MT = 50 ms + 150 ms × log2(D/W + 1). vhid is given a point, not a target, so W is fixed at 20 points, about the height of a button or a line of text. MT is multiplied by a factor drawn from N(1, 0.15), cut off to 0.7–1.3, so two moves over the same distance do not take the same time. A move under a point long takes no time and is just the closing loop.

### The path

A person's aimed movement is a main movement that gets most of the way, then one or more small corrections [2]. Each movement's speed rises and falls in a bell shape, which is what minimising jerk produces [3]:

- **Main movement:** 80% of MT, aimed at a point short of the target by 5% of D (± 3% of D), and off the line by a sideways error of ± 2% of D. Its path bows to one side, by up to 6% of D at the middle, sideways offset × sin(π s) along it. Position along it is the minimum-jerk curve 10s³ − 15s⁴ + 6s⁵ of elapsed time.
- **Correction:** the remaining 20% of MT, a minimum-jerk straight line from wherever the main movement ended to the target.
- **Closing:** `Pointer.move(to:)`'s loop, its reports paced 8 ms apart, for the last fraction of a point the steered path leaves.

There is no added tremor. Rounding each report to whole counts already makes the step lengths uneven.

### Steering the path

Each 8 ms tick asks where the path should be at that tick's deadline, reads where the cursor is, and sends the counts that cover the difference at the gain the last report showed, using the same learning and the same cap on report speed that `Pointer.Gain` uses now. The deadlines are measured from the start of the move, so a late report is followed by a larger one rather than pushing the rest of the path back.

This works because the cursor moves soon after a report. [human-cursor-poll.swift](human-cursor-poll.swift) printed every change of the cursor's location while `vhid play` sent 40 reports of 5 counts, 20 of them 8 ms apart and 20 of them 16 ms apart. Each report moved the cursor exactly once, by 4.35 points every time at both paces. The cursor moved a median of 1.3 ms after the report was sent; 36 of 40 moved within 4.2 ms, and the slowest within 22 ms. Measured against the daemon's acknowledgement, the cursor had usually already moved, and never moved more than 14 ms after it. A read after the acknowledgement, waiting for the cursor to leave where it was as `Pointer.settled` already does, therefore sees the report it follows.

`vhid play`'s calibrated table was the other option. It was ruled out because the calibration is itself motion: bursts of up to 127 counts back and forth before the move starts, which looks nothing like a person, and it would run on every call because each `vhid` call is a new process.

### Clicks

- **Rest on the target before pressing:** N(250, 80) ms, cut off to 120–500 ms. People do pause before they press, and some web menus need hover: on 2026-10-03 a bare `vhid click` on an item in GitHub's repository picker selected nothing three times, while moving, waiting 0.8 s and clicking selected it first time. Whether 250 ms is enough for that picker is checked when the click ticket is built, not here.
- **Hold the button:** N(110, 30) ms, cut off to 60–200 ms [1].
- **Between the clicks of a double or triple click:** N(120, 30) ms from up to down, cut off to 60 ms and to whatever keeps the whole run inside `NSEvent.doubleClickInterval`. The interval is a user setting; both test Macs leave it at macOS's default of 0.5 s.
- **A drag** rests on the start point as a click does, holds the button for 100 ms before carrying it, and rests 100 ms on the end point before letting go.

### Typing

- **From one key-down to the next:** N(180, 60) ms, cut off to 50 ms at the low end [1]. That is about 67 words a minute, a practised typist's speed.
- **Each key held:** N(95, 25) ms, cut off to 40 ms and to 20 ms short of the next key-down, so keys never overlap. No source here measures key holds; 80–120 ms is the range commonly given for them, and it was not checked.
- **Modifiers:** a Shift, Option, Control or Command a keystroke needs goes down 30–80 ms before the key and comes up 20–60 ms after it.
- **A chord** (`vhid press`) uses the same modifier lead and key hold.
- **No typos.** Text that is typed wrong and then corrected is not what a caller asked for.

A character typed as a dead key and then a letter is two keystrokes, and each gets its own gap.

## Sources

1. V. Choudhary et al., "What Does It Take to Detect an AI Agent? Minimal Feature Sets for Behavioral Detection under Browser Automation", arXiv:2607.26935, 2026. Appendix B (click duration, typing speed, teleportation, teleport-click ratio) and Appendix D (the Fitts constants, click holds N(110, 30) ms and key gaps N(180, 60) ms, which it takes as human distributions).
2. D. E. Meyer et al., "Optimality in human motor performance: ideal control of rapid aimed movements", Psychological Review 95(3):340–370, 1988.
3. T. Flash and N. Hogan, "The coordination of arm movements: an experimentally confirmed mathematical model", Journal of Neuroscience 5(7):1688–1703, 1985.

## Repeating it

**The page.** Copy `human-probe.html` and `human-probe.py` to the Mac, run `python3 human-probe.py` in a scratch directory, and open `http://localhost:8765/` in Safari. Find the buttons with `eyes find "Target A"`, then run the verbs against them. The page posts what it saw every half second, and the server appends it to `events.jsonl`, one event a line with the page's own millisecond timestamp. Split pointer events into moves at gaps of more than 300 ms. The page sees what the browser dispatches, about one pointer event a frame, so it understates the event rate of a move that runs longer than a frame.

**The cursor.** Build `human-cursor-poll.swift` with `swiftc -O`, start it for 4 seconds, and while it runs `vhid play` a script of `move` lines. Pair the n-th change it prints with the n-th report `vhid play` prints; each line of `vhid play` carries the report's `sent_us` and `acked_us` on the same clock.

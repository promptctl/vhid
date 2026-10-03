# vhid record takes down a person's keyboard and mouse, and vhid play does it again.
# Nobody sits at the Mac this was filmed on, so events posted through CoreGraphics play
# the person: they reach the recorder as input from outside vhid, which is what a
# person's are. Filmed by scripts/film-demo.

stage() {
    open -a Calculator
    stage_alone Calculator
    vhid press escape
    vhid move 800 250
    five=$(eyes find 5 --exact)
    five=${five##*$'\n'}
    five=${five%%$'\t'*}
}

# The person: the pointer glides to the 5 and clicks it, then the keys 0 - 8 = (US key
# codes 29, 27, 28, 24).
person() {
    osascript -l JavaScript - "${five%,*}" "${five#*,}" <<'JS'
ObjC.import('CoreGraphics')
function run([x, y]) {
    const post = e => $.CGEventPost($.kCGHIDEventTap, e)
    const from = $.CGEventGetLocation($.CGEventCreate(null))
    for (let i = 1; i <= 40; i++) {
        const at = $.CGPointMake(from.x + (x - from.x) * i / 40, from.y + (y - from.y) * i / 40)
        post($.CGEventCreateMouseEvent(null, $.kCGEventMouseMoved, at, 0))
        delay(0.02)
    }
    const at = $.CGPointMake(+x, +y)
    post($.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseDown, at, 0))
    delay(0.08)
    post($.CGEventCreateMouseEvent(null, $.kCGEventLeftMouseUp, at, 0))
    for (const key of [29, 27, 28, 24]) {
        delay(0.35)
        post($.CGEventCreateKeyboardEvent(null, key, true))
        delay(0.06)
        post($.CGEventCreateKeyboardEvent(null, key, false))
    }
}
JS
}

film() {
    start 'vhid record > fifty-less-eight.jsonl'
    say 'a person clicks 5 and types 0-8= (here, posted events stand in for one)'
    person
    sleep 1
    stop
    run 'vhid press escape'
    run 'vhid play < fifty-less-eight.jsonl'
    run 'eyes find 42 --exact'
}

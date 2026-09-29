import ArgumentParser
import Input

/// What a verb is, in words: its name and its description, as both surfaces show it.
///
/// [LAW:one-source-of-truth] `vhid <verb> --help` and the MCP tool list are two renderings
/// of this one value, so what a verb is called and what it says it does cannot drift
/// between them. Only what is true of the command line alone - how a leading `-` is
/// spelled, what the exit status means - is kept out of the tool's description.
struct VerbHelp: Sendable {
    let name: String
    /// One sentence: the CLI's abstract, and the first line of the tool's description.
    let abstract: String
    let discussion: String
    var commandLine: [String] = []

    var configuration: CommandConfiguration {
        CommandConfiguration(commandName: name, abstract: abstract,
                             discussion: ([discussion] + commandLine).joined(separator: "\n\n"))
    }

    /// The tool's description: everything but the command line's notes.
    var tool: String { abstract + "\n\n" + discussion }
}

/// Every verb's and every argument's description, each written once. An argument's is a
/// phrase, which a tool's schema shows as it is and a refusal quotes after "and it is";
/// the command line shows it as a sentence.
enum Help {
    static let place = "screen points from the top left of the main display, the space cursor reports in; negative on a display left of or above it"

    static let x = "the x coordinate, in " + place
    static let y = "the y coordinate, in " + place
    static let text = "the text to type: anything the keyboard layout has keys for, dead-key sequences and line breaks included"
    static let chords = "the chords, pressed in order"
    static let layout = "the keyboard layout to read keys off, by input source id, e.g. com.apple.keylayout.Dvorak; left out, the calling user's own layout, or US English when the system reports none. Name it when the Mac is at the login window or another user is in front, whose layout the caller cannot see"
    static let button = "which button: left, right, middle, or a number from 1 to 32"
    static let times = "how many presses without moving between them, at least 1"
    static let vertical = "wheel ticks, positive rolling the wheel away from the hand. With macOS's Natural scrolling on, as it is by default, that moves the view toward the end of what is scrolled, so the content slides up; with it off, toward the start. Negative is the other way"
    static let horizontal = "wheel ticks, positive tilting the wheel right. With Natural scrolling on, that moves the view toward the left edge; with it off, toward the right. Negative is the other way"
    static let modifiers = "modifier keys held down for the whole act, joined by + the way a chord names them - e.g. leftShift or leftCommand+leftOption - from: " + Modifier.holdableNames
    static let from = "where the button goes down"
    static let to = "where it comes up"

    /// A phrase above as the command line shows it: capitalised, with a full stop.
    static func sentence(_ phrase: String) -> ArgumentHelp {
        ArgumentHelp(phrase.prefix(1).uppercased() + phrase.dropFirst() + ".")
    }

    /// The one order that parses a negative coordinate: every option, then `--`, then the
    /// numbers. Each verb's example is kept as argv so a test parses exactly what the help
    /// prints. [LAW:one-source-of-truth]
    enum NegativeExample {
        static let click = ["click", "--button", "left", "--", "-100", "-40"]
        static let move = ["move", "--", "-100", "-40"]
        static let scroll = ["scroll", "--vertical", "3", "--", "-100", "-40"]
        static let drag = ["drag", "--button", "left", "--", "-100", "40", "200", "40"]
    }

    private static func negative(_ argv: [String]) -> String {
        "Negative coordinates follow --, after every option, as in: vhid \(argv.joined(separator: " "))."
    }

    static let type = VerbHelp(name: "type", abstract: "Type text on the virtual keyboard, which macOS sees as hardware.", discussion: """
        The text goes wherever keys would go if they were pressed now: nothing here chooses or \
        checks what is in front.

        The keyboard layout decides which keys make which characters. Unless one is named, it is \
        the calling user's own, read in this process rather than in the daemon: macOS answers that \
        question per process, and a root daemon asking it is told the US layout whatever the user \
        is typing on. \
        Text it has no keys for is refused whole, before any key goes down.
        """, commandLine: ["Text starting with - follows --, as in: vhid type -- \"-5 degrees\"."])

    static let press = VerbHelp(name: "press", abstract: "Press chords on the virtual keyboard, one after another.", discussion: """
        A chord is modifier names and one key joined by +, e.g. leftCommand+s or \
        leftShift+leftCommand+left. A key is a name (\(KeyChord.keyNameList)), \
        the character the layout types with it (with Command held first, in a chord that holds Command), \
        or a key code written key 0x24.

        Which key a letter is on is the layout's to say - s is key code 1 on US and 41 on Dvorak - so \
        a chord is read against the named layout or, unless one is named, the calling user's own, \
        read in this process rather than in the daemon.

        Every chord is proven pressable before the first one goes down.
        """)

    static let click = VerbHelp(name: "click", abstract: "Click at a point on the screen.", discussion: """
        Coordinates, and nothing else: there is no click-by-element here, because nothing in vhid \
        reads the screen. What is under the point is the caller's to know.

        The device sends counts, not coordinates, and macOS accelerates them, so the pointer is \
        steered in a loop - post a delta, read the cursor back, repeat - and the point it reports \
        landing at is read back from the cursor rather than the point that was asked for. The two \
        can differ by under a point.
        """, commandLine: [negative(NegativeExample.click)])

    static let move = VerbHelp(name: "move", abstract: "Move the pointer to a point on the screen, pressing nothing.", discussion: """
        Steered the way click steers it - post a delta, read the cursor back, repeat - and the \
        point it reports is read back from the cursor.
        """, commandLine: [negative(NegativeExample.move)])

    static let scroll = VerbHelp(name: "scroll", abstract: "Roll the mouse wheel at a point on the screen.", discussion: """
        The pointer is moved to the point first, because a wheel scrolls whatever is under the \
        pointer. The ticks are the device's own, and macOS decides how far each one scrolls.
        """, commandLine: [negative(NegativeExample.scroll)])

    static let drag = VerbHelp(name: "drag", abstract: "Drag from one point on the screen to another.", discussion: """
        The pointer is moved to the first point, the button goes down, the pointer is moved to \
        the second with it held, and every button comes up. Both points it reports are read \
        back from the cursor.
        """, commandLine: [negative(NegativeExample.drag)])

    static let script = "the script, as JSON Lines: the start line, then one act a line"

    static let play = VerbHelp(name: "play", abstract: "Replay a timed script of keyboard and mouse acts, one report each, and say when each went out.", discussion: """
        The script is JSON Lines. The first line is where the cursor starts, reached before the \
        clock starts: {"to":{"x":800,"y":500}}, in \(place). Every line after it is one act at t_ms \
        milliseconds from the clock's start, in order:
          {"t_ms":0,"keys":["leftShift",4]}       exactly these keys held from now: a modifier (\(Modifier.holdableNames)), \
        a key name (\(KeyChord.keyNameList)), or a usage number from 4 to 231 - the physical key, never a character
          {"t_ms":0,"buttons":["left"]}           exactly these buttons held from now: left, right, middle, or 1 to 32
          {"t_ms":8.3,"move":{"dx":4,"dy":-2}}    relative motion in counts, -127 to 127, uncorrected
          {"t_ms":8.3,"at":{"x":812.5,"y":400}}   the cursor should be here now, in the start's coordinates
          {"t_ms":16.7,"wheel":{"v":-1,"h":0}}    wheel ticks, -127 to 127; v positive rolls away from the hand
          {"t_ms":1000,"keys":[]}                 every key up; {"buttons":[]} every button
        A script is refused whole, before anything is connected, if a line is malformed, t_ms goes \
        backwards or past an hour, a keys line holds more than 32 keys besides the modifiers, or it \
        ends with a key or a button held. A line that repeats the held set sends nothing and \
        prints no report line. A key held through a second with no other act is said again, which \
        keeps it held and sends no report.

        A script moves the pointer with move lines or with at lines, never both. Move counts are \
        the input, sent as written. At lines are steered: before the clock starts, reports of a few \
        sizes are sent at the script's own pace and the cursor read back, and between clicks each at \
        line is the report that measurement says covers the step, the cursor not read. Before every \
        buttons line and at the end, the pointer is steered in a loop onto the last at point - or \
        the start - so every press and release lands where the script says, and later lines wait for \
        as long as that took. A cursor that will not get there stops the play at that line.

        A finished play answers {"done":{"reports":…,"start_reports":…,"late_us":{"p50":…,"p90":…,"p99":…,"max":…}}}: \
        how many reports went out, how many the pointer took to reach the start, and how late \
        they went out in microseconds, sent minus scheduled. A late report is sent late, never \
        skipped. A play that stops releases every key and button and fails, saying how many \
        reports went out before it did.
        """, commandLine: ["""
        The script is read from stdin. Before the done line, stdout carries one \
        {"report":{"index":…,"line":…,"scheduled_us":…,"sent_us":…,"acked_us":…}} per report, line \
        being the script line it came from, times in microseconds since the Unix epoch. A play that \
        stops prints the reports that did go out and no done line - the missing done line is what \
        says it stopped.
        """])

    static let cursor = VerbHelp(name: "cursor", abstract: "Say where the pointer is, in the coordinates click takes.", discussion: """
        Read by the daemon in the session in front - the login window's, or another user's, \
        as much as your own - since a read made outside that session answers (0, 0). Claims \
        nothing, so it answers while another client holds the devices.
        """)

    static let record = VerbHelp(name: "record", abstract: "Record the physical keyboard and mouse as a script vhid play replays.", discussion: """
        Prints the script on stdout when the recording stops: Control-C stops it and the \
        Control-C is not in it; SIGTERM stops it and drops nothing; an hour stops it, the \
        longest a script plays. Keys are recorded as the physical keys held, the pointer as \
        at points, and anything vhid itself sends while recording is left out.

        The tap runs in vhid-record.app, which needs Input Monitoring: the first run is \
        refused and lists it in System Settings > Privacy & Security > Input Monitoring, \
        where it is switched on once. Refused while another process holds the devices, and \
        while Karabiner-Elements is running, whose keys come through vhid's driver and \
        could not be told from vhid's.
        """, commandLine: ["Notes, such as key presses with no HID usage left out, go to stderr."])

    static let doctor = VerbHelp(name: "doctor", abstract: "Name every requirement a verb needs, and the step left for any that is not met.", discussion: """
        First ready or not ready, then one row per requirement - the driver extension, the \
        daemon's launchd job, the daemon, its admitting this vhid, who holds the devices, the \
        Keyboard Setup Assistant answer - in the order they depend on each other: what it is, \
        what was read on this Mac, and, indented under it, the step left for a person. Nothing \
        is fixed, and the devices are not taken from a client that holds them; a daemon launchd \
        has a job for but has not started is started by the question, as it would be by any verb.
        """, commandLine: ["Exits 1 when any row has a step."])
}

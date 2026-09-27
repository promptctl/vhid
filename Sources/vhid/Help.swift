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

        The console user's own keyboard layout decides which keys make which characters, and it \
        is read in this process rather than in the daemon: macOS answers that question per \
        process, and a root daemon asking it is told the US layout whatever the user is typing on. \
        Text it has no keys for is refused whole, before any key goes down.
        """, commandLine: ["Text starting with - follows --, as in: vhid type -- \"-5 degrees\"."])

    static let press = VerbHelp(name: "press", abstract: "Press chords on the virtual keyboard, one after another.", discussion: """
        A chord is modifier names and one key joined by +, e.g. leftCommand+s or \
        leftShift+leftCommand+left. A key is a name (\(KeyChord.keyNameList)), \
        the character the layout types with it (with Command held first, in a chord that holds Command), \
        or a key code written key 0x24.

        Which key a letter is on is the layout's to say - s is key code 1 on US and 41 on Dvorak - so \
        a chord is read against the console user's layout, in this process rather than in the daemon.

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

    static let cursor = VerbHelp(name: "cursor", abstract: "Say where the pointer is, in the coordinates click takes.", discussion: """
        Read from the window server rather than from the daemon, which cannot know: macOS \
        accelerates what the device sends, so where the pointer went is a fact of the user's \
        session. This verb reaches no daemon at all.
        """)

    static let doctor = VerbHelp(name: "doctor", abstract: "Name every requirement a verb needs, and the step left for any that is not met.", discussion: """
        First ready or not ready, then one row per requirement - the driver extension, the \
        daemon's launchd job, the daemon, its admitting this vhid, who holds the devices, the \
        Keyboard Setup Assistant answer - in the order they depend on each other: what it is, \
        what was read on this Mac, and, indented under it, the step left for a person. Nothing \
        is fixed, and the devices are not taken from a client that holds them; a daemon launchd \
        has a job for but has not started is started by the question, as it would be by any verb.
        """, commandLine: ["Exits 1 when any row has a step."])
}

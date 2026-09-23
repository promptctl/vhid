import Input
import Installations
import KeyboardLayout
import MCP
import Pointing

/// One verb as an MCP tool: what a client is shown, and what a call does.
///
/// [LAW:one-type-per-behavior] Seven tools and one type. What differs between them is a
/// name, a sentence, a list of parameters and a verb to run, and all four are values.
struct VerbTool: Sendable {
    let tool: Tool
    private let parameters: [any DeclaredParameter]
    private let perform: @Sendable (Arguments, Installation) async throws -> String

    init(_ name: String, _ description: String, readOnly: Bool = false, _ parameters: [any DeclaredParameter],
         perform: @escaping @Sendable (Arguments, Installation) async throws -> String) {
        tool = Tool(
            name: name, description: description,
            inputSchema: .object([
                "type": "object",
                "properties": .object(Dictionary(uniqueKeysWithValues: parameters.map { ($0.name, $0.property) })),
                "required": .array(parameters.filter(\.required).map { .string($0.name) }),
                "additionalProperties": false,
            ]),
            annotations: .init(readOnlyHint: readOnly, destructiveHint: readOnly ? nil : true, openWorldHint: true))
        self.parameters = parameters
        self.perform = perform
    }

    /// Runs the verb against `installation`'s daemon and says what it did.
    ///
    /// **Every call reaches the daemon afresh.** A verb reaches the devices through
    /// `Devices.using` inside `perform`, exactly as the CLI's `run` does, and hands them
    /// back before it returns. So the daemon, which admits one client at a time, is held
    /// for the length of one call and never for the length of a session. A shell's
    /// `vhid click` between two calls finds it free, and so does a second agent's session.
    /// [LAW:no-ambient-temporal-coupling] The holding is a scope, not a policy.
    ///
    /// Every argument is read before the scope opens, so an argument that is refused never
    /// reaches the daemon at all.
    func call(_ given: [String: Value], on installation: Installation) async throws -> String {
        try await perform(try Arguments(given, for: parameters), installation)
    }
}

/// The seven tools, in the order a client lists them.
///
/// Each is a CLI verb's core called with arguments read from JSON rather than from argv,
/// so a tool and its verb cannot come to do different things. [LAW:one-source-of-truth]
enum Tools {
    static let all: [VerbTool] = [type, press, click, move, scroll, drag, cursor]

    private static let place = "screen points from the top left of the main display, the space cursor reports in; negative on a display left of or above it"

    private static let x = Parameter.number("x", "the x coordinate, in " + place)
    private static let y = Parameter.number("y", "the y coordinate, in " + place)

    /// Two coordinates as one place. Never refused for a JSON number: every number JSON
    /// hands over is finite, and the one that is not, `1e400`, never gets this far.
    /// `AnsweringTransport` answers for it. The refusal is still `place`'s, worded once for
    /// the command line and here alike. [LAW:single-enforcer]
    private static func point(_ arguments: Arguments) throws -> ScreenPoint {
        try vhid.place(try arguments[x], try arguments[y])
    }

    static let type: VerbTool = {
        let text = Parameter.text("text", "the text to type: anything the keyboard layout has keys for, dead-key sequences and line breaks included")
        return VerbTool("type", """
            Type text on the virtual keyboard, which macOS sees as hardware. It goes wherever keys would \
            go if pressed now: nothing chooses or checks what is in front. The console user's keyboard \
            layout decides which keys make which characters, and text it cannot type is refused whole \
            before any key goes down.
            """, [text]) { arguments, installation in
            let (text, layout) = (try arguments[text], try KeyboardLayout.current())
            return try await Devices.using(installation) { try await TypeCommand.type(text, on: layout, with: $0.typist) }
        }
    }()

    static let press: VerbTool = {
        let chords = Parameter.texts("chords", """
            the chords, pressed in order. A chord is modifier names and one key joined by +, e.g. \
            leftCommand+s or leftShift+leftCommand+left. A key is a name \
            (\(KeyChord.namedKeys.keys.sorted().joined(separator: ", "))), the character the layout \
            types with it and nothing held, or a key code written key 0x24
            """)
        return VerbTool("press", """
            Press chords on the virtual keyboard, one after another. Every chord is proven pressable \
            before the first one goes down.
            """, [chords]) { arguments, installation in
            let (chords, layout) = (try arguments[chords], try KeyboardLayout.current())
            return try await Devices.using(installation) { try await KeysCommand.press(chords, on: layout, with: $0.typist) }
        }
    }()

    static let click: VerbTool = {
        let button = Parameter.button("button").absent(.left)
        let count = Parameter.clicks("count").absent(.single)
        return VerbTool("click", """
            Move the pointer to a point on the screen and click there. The point it reports is read \
            back from the cursor, and can differ from the one asked for by under a point.
            """, [x, y, button, count]) { arguments, installation in
            let (at, button, count) = (try point(arguments), try arguments[button], try arguments[count])
            return try await Devices.using(installation) { try await ClickCommand.click(at: at, button: button, times: count, with: $0.pointer) }
        }
    }()

    static let move: VerbTool = VerbTool("move", """
        Move the pointer to a point on the screen, pressing nothing. The point it reports is read \
        back from the cursor.
        """, [x, y]) { arguments, installation in
        let to = try point(arguments)
        return try await Devices.using(installation) { try await MoveCommand.move(to: to, with: $0.pointer) }
    }

    static let scroll: VerbTool = {
        let vertical = Parameter.whole("vertical", "wheel ticks, positive rolling the wheel away from the hand. With macOS's Natural scrolling on, as it is by default, that moves the view toward the end of what is scrolled, so the content slides up; with it off, toward the start. Negative is the other way").absent(0)
        let horizontal = Parameter.whole("horizontal", "wheel ticks, positive tilting the wheel right. With Natural scrolling on, that moves the view toward the left edge; with it off, toward the right. Negative is the other way").absent(0)
        return VerbTool("scroll", """
            Move the pointer to a point and roll the mouse wheel there, since a wheel scrolls whatever \
            is under the pointer. How far one tick scrolls is macOS's to decide.
            """, [x, y, vertical, horizontal]) { arguments, installation in
            let (at, vertical, horizontal) = (try point(arguments), try arguments[vertical], try arguments[horizontal])
            return try await Devices.using(installation) {
                try await ScrollCommand.scroll(at: at, vertical: vertical, horizontal: horizontal, with: $0.pointer)
            }
        }
    }()

    static let drag: VerbTool = {
        let from = Parameter.place("from", "where the button goes down")
        let to = Parameter.place("to", "where it comes up")
        let button = Parameter.button("button").absent(.left)
        return VerbTool("drag", """
            Press a button at one point, carry it to another with the button held, and let go. Both \
            points it reports are read back from the cursor.
            """, [from, to, button]) { arguments, installation in
            let (from, to, button) = (try arguments[from], try arguments[to], try arguments[button])
            return try await Devices.using(installation) { try await DragCommand.drag(from: from, to: to, button: button, with: $0.pointer) }
        }
    }()

    /// The one tool that reaches no daemon: where the cursor is, the window server knows.
    static let cursor: VerbTool = VerbTool("cursor", """
        Where the pointer is now, in the coordinates click takes. Read from the window server.
        """, readOnly: true, []) { _, _ in
        try CursorCommand.cursor(Pointer.screenCursor)
    }
}

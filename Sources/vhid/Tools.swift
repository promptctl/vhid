import Dispatch
import Doctor
import Input
import Installations
import KeyboardLayouts
import MCP
import Pointing

/// One verb as an MCP tool: what a client is shown, and what a call does.
///
/// [LAW:one-type-per-behavior] Every tool, one type. What differs between them is a
/// verb's help, a list of parameters and a verb to run, and all three are values.
struct VerbTool: Sendable {
    let tool: Tool
    private let parameters: [any DeclaredParameter]
    private let perform: @Sendable (Arguments, Installation) async throws -> String

    init(_ help: VerbHelp, readOnly: Bool = false, _ parameters: [any DeclaredParameter],
         perform: @escaping @Sendable (Arguments, Installation) async throws -> String) {
        tool = Tool(
            name: help.name, description: help.tool,
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
    /// back before it returns. So the daemon, which serves one client at a time, is held
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

/// Every tool, in the order a client lists them.
///
/// Each is a CLI verb's core called with arguments read from JSON rather than from argv,
/// so a tool and its verb cannot come to do different things. [LAW:one-source-of-truth]
enum Tools {
    static let all: [VerbTool] = [type, press, click, move, scroll, drag, cursor, doctor]

    private static let x = Parameter.number("x", Help.x)
    private static let y = Parameter.number("y", Help.y)

    /// Two coordinates as one place. Never refused for a JSON number: every number JSON
    /// hands over is finite, and the one that is not, `1e400`, never gets this far.
    /// `AnsweringTransport` answers for it. The refusal is still `place`'s, worded once for
    /// the command line and here alike. [LAW:single-enforcer]
    private static func point(_ arguments: Arguments) throws -> ScreenPoint {
        try vhid.place(try arguments[x], try arguments[y])
    }

    static let type: VerbTool = {
        let text = Parameter.text("text", Help.text)
        return VerbTool(Help.type, [text]) { arguments, installation in
            let (text, layout) = (try arguments[text], try KeyboardLayout.current())
            return try await Devices.using(installation) { try await TypeCommand.type(text, on: layout, with: $0.typist) }
        }
    }()

    static let press: VerbTool = {
        let chords = Parameter.texts("chords", Help.chords)
        return VerbTool(Help.press, [chords]) { arguments, installation in
            let (chords, layout) = (try arguments[chords], try KeyboardLayout.current())
            return try await Devices.using(installation) { try await PressCommand.press(chords, on: layout, with: $0.typist) }
        }
    }()

    static let click: VerbTool = {
        let button = Parameter.button("button").absent(.left)
        let times = Parameter.clicks("times").absent(.single)
        return VerbTool(Help.click, [x, y, button, times]) { arguments, installation in
            let (at, button, times) = (try point(arguments), try arguments[button], try arguments[times])
            return try await Devices.using(installation) { try await ClickCommand.click(at: at, button: button, times: times, with: $0.pointer) }
        }
    }()

    static let move: VerbTool = VerbTool(Help.move, [x, y]) { arguments, installation in
        let to = try point(arguments)
        return try await Devices.using(installation) { try await MoveCommand.move(to: to, with: $0.pointer) }
    }

    static let scroll: VerbTool = {
        let vertical = Parameter.whole("vertical", Help.vertical).absent(0)
        let horizontal = Parameter.whole("horizontal", Help.horizontal).absent(0)
        return VerbTool(Help.scroll, [x, y, vertical, horizontal]) { arguments, installation in
            let (at, vertical, horizontal) = (try point(arguments), try arguments[vertical], try arguments[horizontal])
            return try await Devices.using(installation) {
                try await ScrollCommand.scroll(at: at, vertical: vertical, horizontal: horizontal, with: $0.pointer)
            }
        }
    }()

    static let drag: VerbTool = {
        let from = Parameter.place("from", Help.from)
        let to = Parameter.place("to", Help.to)
        let button = Parameter.button("button").absent(.left)
        return VerbTool(Help.drag, [from, to, button]) { arguments, installation in
            let (from, to, button) = (try arguments[from], try arguments[to], try arguments[button])
            return try await Devices.using(installation) { try await DragCommand.drag(from: from, to: to, button: button, with: $0.pointer) }
        }
    }()

    /// The one tool that reaches no daemon: where the cursor is, the window server knows.
    static let cursor: VerbTool = VerbTool(Help.cursor, readOnly: true, []) { _, _ in
        try CursorCommand.cursor(Pointer.screenCursor)
    }

    /// `vhid doctor` as a tool. A Mac that is not ready is an answer and not a failure of
    /// the call, so it comes back as what the verb prints, whose first line says it.
    ///
    /// The reading waits on subprocesses and on a status reply of up to five seconds, so it
    /// is taken on a dispatch thread and not on the cooperative pool, whose few threads the
    /// server's transport runs on too - the same move `DeviceQueue` makes for the device
    /// calls. [LAW:no-ambient-temporal-coupling]
    static let doctor: VerbTool = VerbTool(Help.doctor, readOnly: true, []) { _, installation in
        let readiness = await withCheckedContinuation { reading in
            DispatchQueue.global().async { reading.resume(returning: Readiness.read(for: installation)) }
        }
        return DoctorCommand.doctor(readiness)
    }
}

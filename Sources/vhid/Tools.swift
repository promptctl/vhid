import Dispatch
import Doctor
import Helper
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
    static let all: [VerbTool] = [type, press, gesture, click, move, scroll, drag, play, cursor, doctor]

    private static let x = Parameter.number("x", Help.x)
    private static let y = Parameter.number("y", Help.y)
    private static let modifiers = Parameter.modifiers("modifiers").absent(.none)
    private static let layoutName = Parameter.layout("layout")
    private static let into = Parameter.aim("into")

    /// Two coordinates as one place. Never refused for a JSON number: every number JSON
    /// hands over is finite, and the one that is not, `1e400`, never gets this far.
    /// `AnsweringTransport` answers for it. The refusal is still `place`'s, worded once for
    /// the command line and here alike. [LAW:single-enforcer]
    private static func point(_ arguments: Arguments) throws -> ScreenPoint {
        try vhid.place(try arguments[x], try arguments[y])
    }

    static let type: VerbTool = {
        let text = Parameter.text("text", Help.text)
        return VerbTool(Help.type, [text, layoutName, into]) { arguments, installation in
            let (text, layout, aim) = (try arguments[text], try KeyboardLayout.chosen(try arguments[layoutName]), try arguments[into])
            return try await Devices.using(installation) { try await TypeCommand.type(text, on: layout, into: aim, with: $0.typist, front: $0.front) }
        }
    }()

    static let press: VerbTool = {
        let chords = Parameter.texts("chords", Help.chords)
        return VerbTool(Help.press, [chords, layoutName, into]) { arguments, installation in
            let (chords, layout, aim) = (try arguments[chords], try KeyboardLayout.chosen(try arguments[layoutName]), try arguments[into])
            return try await Devices.using(installation) { try await PressCommand.press(chords, on: layout, into: aim, with: $0.typist, front: $0.front) }
        }
    }()

    static let gesture: VerbTool = {
        let gesture = Parameter.gesture("gesture")
        return VerbTool(Help.gesture, [gesture, layoutName]) { arguments, installation in
            let chord = try GestureCommand.chord(for: try arguments[gesture], on: try KeyboardLayout.chosen(try arguments[layoutName]),
                                                 hotKeys: GestureCommand.hotKeys)
            return try await Devices.using(installation) { try await GestureCommand.perform(chord, with: $0.typist) }
        }
    }()

    static let click: VerbTool = {
        let button = Parameter.button("button").absent(.left)
        let times = Parameter.clicks("times").absent(.single)
        return VerbTool(Help.click, [x, y, button, times, modifiers]) { arguments, installation in
            let (at, button, times, held) = (try point(arguments), try arguments[button], try arguments[times], try arguments[modifiers])
            return try await Devices.using(installation) {
                try await ClickCommand.click(at: at, button: button, times: times, holding: held, with: $0.pointer, $0.keyboard)
            }
        }
    }()

    static let move: VerbTool = VerbTool(Help.move, [x, y]) { arguments, installation in
        let to = try point(arguments)
        return try await Devices.using(installation) { try await MoveCommand.move(to: to, with: $0.pointer) }
    }

    static let scroll: VerbTool = {
        let vertical = Parameter.whole("vertical", Help.vertical).absent(0)
        let horizontal = Parameter.whole("horizontal", Help.horizontal).absent(0)
        return VerbTool(Help.scroll, [x, y, vertical, horizontal, modifiers]) { arguments, installation in
            let (at, vertical, horizontal, held) = (try point(arguments), try arguments[vertical], try arguments[horizontal], try arguments[modifiers])
            return try await Devices.using(installation) {
                try await ScrollCommand.scroll(at: at, vertical: vertical, horizontal: horizontal, holding: held, with: $0.pointer, $0.keyboard, clock: ContinuousClock())
            }
        }
    }()

    static let drag: VerbTool = {
        let from = Parameter.place("from", Help.from)
        let to = Parameter.place("to", Help.to)
        let button = Parameter.button("button").absent(.left)
        return VerbTool(Help.drag, [from, to, button, modifiers]) { arguments, installation in
            let (from, to, button, held) = (try arguments[from], try arguments[to], try arguments[button], try arguments[modifiers])
            return try await Devices.using(installation) {
                try await DragCommand.drag(from: from, to: to, button: button, holding: held, with: $0.pointer, $0.keyboard)
            }
        }
    }()

    /// The done line `vhid play` prints, as the call's answer. A play that stops is the
    /// tool's error, which says how many reports went out before it did.
    static let play: VerbTool = {
        let script = Parameter.text("script", Help.script)
        return VerbTool(Help.play, [script]) { arguments, installation in
            let schedule = try PlayCommand.schedule(try arguments[script])
            let played = try await Devices.using(installation) { try await PlayCommand.play(schedule, with: $0) }
            return try PlayCommand.done(played)
        }
    }()

    /// Where the cursor is, as the daemon reads it in the session in front.
    static let cursor: VerbTool = VerbTool(Help.cursor, readOnly: true, []) { _, installation in
        try await CursorCommand.cursor(Devices.cursor(HelperConnection(installation: installation), on: DeviceQueue()))
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

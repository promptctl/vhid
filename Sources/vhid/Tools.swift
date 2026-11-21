import ArgumentParser
import Dispatch
import Doctor
import EyesVerbs
import Helper
import Input
import Installations
import KeyboardLayouts
import MCP
import Pointing
import enum Seeing.SourceKind
import enum Seeing.Until
import Telemetry
import Turns

/// One verb as an MCP tool: what a client is shown, and what a call does.
///
/// [LAW:one-type-per-behavior] Every tool, one type. What differs between them is a
/// verb's help, a list of parameters and a verb to run, and all three are values.
struct VerbTool: Sendable {
    let tool: Tool
    private let parameters: [any DeclaredParameter]
    private let perform: Perform

    /// What a call does, and so whether it waits its turn for the daemon.
    enum Perform: Sendable {
        /// Reaches the daemon, which serves one client at a time, so the call takes the
        /// session's turn.
        case daemon(@Sendable (Arguments, Installation) async throws -> String)
        /// Reads the screen in this process and asks nothing of the daemon, so it waits
        /// behind no device call.
        case screen(@Sendable (Arguments) async throws -> String)
    }

    init(_ help: VerbHelp, readOnly: Bool = false, _ parameters: [any DeclaredParameter],
         perform: @escaping @Sendable (Arguments, Installation) async throws -> String) {
        self.init(help, readOnly: readOnly, parameters, .daemon(perform))
    }

    /// A tool that reads the screen, which changes nothing.
    init(screen help: VerbHelp, _ parameters: [any DeclaredParameter], reading: @escaping @Sendable (Arguments) async throws -> String) {
        self.init(help, readOnly: true, parameters, .screen(reading))
    }

    private init(_ help: VerbHelp, readOnly: Bool, _ parameters: [any DeclaredParameter], _ perform: Perform) {
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

    /// Runs the verb and says what it did: against `installation`'s daemon in its turn of
    /// `turns`, or on the screen, at once.
    ///
    /// **Every call reaches the daemon afresh.** A verb reaches the devices through
    /// `Devices.using` inside `perform`, exactly as the CLI's `run` does, and hands them
    /// back before it returns. So the daemon, which serves one client at a time, is held
    /// for the length of one call and never for the length of a session. A shell's
    /// `vhid click` between two calls finds it free, and so does a second agent's session.
    /// [LAW:no-ambient-temporal-coupling] The holding is a scope, not a policy.
    ///
    /// Every argument is read before the call waits its turn, so an argument that is
    /// refused never waits, and never reaches the daemon at all.
    func call(_ given: [String: Value], on installation: Installation, taking turns: Turns, arrived: ContinuousClock.Instant) async throws -> String {
        let arguments = try Arguments(given, for: parameters)
        switch perform {
        case .screen(let read):
            return try await read(arguments)
        case .daemon(let act):
            return try await turns.take {
                Telemetry.note(.queuedMilliseconds, .double((ContinuousClock.now - arrived) / .milliseconds(1)))
                return try await act(arguments, installation)
            }
        }
    }
}

/// Every tool, in the order a client lists them.
///
/// Each is a CLI verb's core called with arguments read from JSON rather than from argv,
/// so a tool and its verb cannot come to do different things. [LAW:one-source-of-truth]
enum Tools {
    static let all: [VerbTool] = [look(), type, press, gesture, click, move, scroll, drag, play, cursor, doctor]

    private static let x = Parameter.number("x", Help.x + ", given with y unless box is").optional
    private static let y = Parameter.number("y", Help.y + ", given with x unless box is").optional
    private static let box = Parameter.box("box", Help.box).optional
    private static let modifiers = Parameter.modifiers("modifiers").absent(.none)
    private static let layoutName = Parameter.layout("layout")
    private static let into = Parameter.aim("into")

    /// Where a tool that takes one place is aimed: two coordinates as a point, or a box,
    /// and refused as neither or both. A point is never refused for a JSON number: every
    /// number JSON hands over is finite, and the one that is not, `1e400`, never gets this
    /// far. `AnsweringTransport` answers for it. The refusal is still `place`'s, worded once
    /// for the command line and here alike. [LAW:single-enforcer]
    private static func target(_ arguments: Arguments) throws -> Target {
        switch (try arguments[x], try arguments[y], try arguments[box]) {
        case let (x?, y?, nil): .point(try vhid.place(x, y))
        case let (nil, nil, box?): .box(box)
        default: throw ArgumentRefused("give x and y, or box, and not both")
        }
    }

    /// What is on screen, read in this process: the arguments `vhid look` takes, read by
    /// the one rule it reads them by. [LAW:single-enforcer]
    static func look(on screen: Screen = .live) -> VerbTool {
        let text = Parameter.text("text", LookHelp.text).optional
        let exact = Parameter.flag("exact", LookHelp.exact).absent(false)
        let edits = Parameter.whole("edits", LookHelp.edits).optional
        let near = Parameter.text("near", LookHelp.near).optional
        let until = Parameter<Until>.choice("until", LookHelp.until).optional
        let timeout = Parameter.number("timeout", LookHelp.timeout).optional
        let display = Parameter.id("display", LookHelp.display).optional
        let window = Parameter.id("window", LookHelp.window).optional
        let page = Parameter.id("page", LookHelp.page).optional
        let rect = Parameter.text("rect", LookHelp.rect).optional
        let app = Parameter.text("app", LookHelp.app).optional
        let limit = Parameter.whole("limit", LookHelp.limit).optional
        let source = Parameter<SourceKind>.choice("source", LookHelp.source).optional
        let role = Parameter.text("role", LookHelp.role).optional
        let x = Parameter.number("x", Help.lookX).optional
        let y = Parameter.number("y", Help.lookY).optional
        return VerbTool(screen: Help.look, [text, exact, edits, near, until, timeout, display, window, page, rect, app, limit, source, role, x, y]) { arguments in
            let asked: Asked
            do {
                asked = try Asked.parsed(
                    text: try arguments[text], exact: try arguments[exact], edits: try arguments[edits], near: try arguments[near],
                    until: try arguments[until], timeout: try arguments[timeout], display: try arguments[display], window: try arguments[window],
                    page: try arguments[page], rect: try arguments[rect], app: try arguments[app], limit: try arguments[limit],
                    source: try arguments[source], role: try arguments[role], x: try arguments[x], y: try arguments[y], as: .argument)
            } catch let refused as ValidationError {
                throw ArgumentRefused(refused.message)
            }
            return try await asked.answer(on: screen)
        }
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
        return VerbTool(Help.click, [x, y, box, button, times, modifiers]) { arguments, installation in
            let (at, button, times, held) = (try target(arguments), try arguments[button], try arguments[times], try arguments[modifiers])
            return try await Devices.using(installation) {
                try await ClickCommand.click(at: at, button: button, times: times, holding: held, with: $0.pointer, $0.keyboard)
            }
        }
    }()

    static let move: VerbTool = VerbTool(Help.move, [x, y, box]) { arguments, installation in
        let to = try target(arguments)
        return try await Devices.using(installation) { try await MoveCommand.move(to: to, with: $0.pointer) }
    }

    static let scroll: VerbTool = {
        let vertical = Parameter.whole("vertical", Help.vertical).absent(0)
        let horizontal = Parameter.whole("horizontal", Help.horizontal).absent(0)
        return VerbTool(Help.scroll, [x, y, box, vertical, horizontal, modifiers]) { arguments, installation in
            let (at, vertical, horizontal, held) = (try target(arguments), try arguments[vertical], try arguments[horizontal], try arguments[modifiers])
            return try await Devices.using(installation) {
                try await ScrollCommand.scroll(at: at, vertical: vertical, horizontal: horizontal, holding: held, with: $0.pointer, $0.keyboard)
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
    static let doctor: VerbTool = VerbTool(Help.doctor, readOnly: true, []) { _, installation in
        DoctorCommand.doctor(try await reading { Readiness.read(for: installation, stoppedBy: $0) })
    }
}

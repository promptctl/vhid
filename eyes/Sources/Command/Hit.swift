import AppKit
import ArgumentParser
import Eyes
import Telemetry
import Tree

/// What a click at a point would hit, asked right before acting on it: which app and window
/// it goes to, and which element it presses. A question, never a guard - nothing is refused on
/// its answer, and `vhid click` presses what is there whatever eyes said.
struct Hit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Say what a click at a point would hit: the app and window it lands in, and the element it presses with the ones that hold it.",
        discussion: "Asks the system's own hit test at the point, as vhid click takes it, and reads each element up to the area holding it - a window, a list, a toolbar, a web page. Says whether a look with no place named reads that app. Needs Accessibility. A negative coordinate, on a display left of or above the main one, follows --, as vhid click takes it: eyes hit -- -500 300."
    )

    @Argument(help: "The point's x, in the screen points vhid click takes.")
    var x: Double

    @Argument(help: "The point's y, in the same points.")
    var y: Double

    func validate() throws { _ = try Self.point(x, y) }

    @MainActor
    func run() async throws {
        print(try await Self.answer(at: Self.point(x, y)) { try await Self.land(at: $0) })
    }

    /// Two numbers as a point, or the refusal: `inf` and `nan` are numbers a shell hands over.
    /// [LAW:parse-dont-validate] One rule for the verb and the MCP tool. [LAW:single-enforcer]
    static func point(_ x: Double, _ y: Double) throws -> ScreenPoint {
        guard x.isFinite, y.isFinite else { throw ValidationError("(\(x), \(y)) is not a place on the screen") }
        return ScreenPoint(x: x, y: y)
    }

    /// Where a click at a point lands, nil when nothing is there: the process in it, a fake in
    /// a test. [LAW:effects-at-boundaries]
    typealias Landings = @Sendable (ScreenPoint) async throws -> Landing?

    /// The report a verb prints and a tool answers, from the one unit of work both go through.
    /// [LAW:one-source-of-truth] [LAW:nothing-unseen] One `hit` event per question: the app and
    /// where it stands, the window, how far the climb read and how it ended.
    static func answer(at point: ScreenPoint, landing: Landings) async throws -> String {
        try await Telemetry.unit("hit", outcome: { $0.0 == nil ? "nothing" : "landed" }) {
            Telemetry.count("rows", 0)
            Telemetry.count("calls", 0)
            let landed = try await landing(point)
            if let landed {
                Telemetry.note("app", landed.app.name ?? "")
                Telemetry.note("standing", landed.standing.said)
                Telemetry.note("end", landed.end.said)
                Telemetry.count("pid", Int(landed.app.pid))
                Telemetry.count("window", Int(landed.window?.id ?? 0))
                Telemetry.count("rows", landed.elements.count)
                Telemetry.count("calls", landed.calls)
            } else {
                Telemetry.note("end", "nothing")
            }
            return (landed, report(at: point, landed))
        }.1
    }

    /// The scope line, then a row per element, the one hit first. Pure, so every sentence a
    /// caller trusts is checked by a test. [LAW:effects-at-boundaries]
    static func report(at point: ScreenPoint, _ landed: Landing?) -> String {
        guard let landed else {
            return "A click at \(point) hits no element: the system's hit test answered that nothing is there."
        }
        let window = landed.window.map { "in its window \($0.id) at \($0.frame)" }
            ?? "in none of its listed windows"
        let scope = "A click at \(point) lands in \(landed.app), \(standing(landed.standing)), \(window)."
            + " \(ended(landed.end, rows: landed.elements.count))"
            + " Each row: role, frame as x,y,width,height in vhid click coordinates, then what it says."
        return ([scope] + landed.elements.map(row)).joined(separator: "\n")
    }

    private static func standing(_ standing: Standing) -> String {
        switch standing {
        case .front: "the front app, which a look with no place named reads"
        case .overFront(let front): "a window over the front app \(front), which a look with no place named reads too"
        case .own: "the app eyes answers to, whose windows a look never reads: the agent's own terminal or app"
        case .behind(let front?): "not in front: a look with no place named reads \(front)"
        case .behind(nil): "not in front: nothing but the app eyes answers to has a window on screen"
        }
    }

    private static func ended(_ end: Landing.End, rows: Int) -> String {
        switch end {
        case .area: "The element hit, then each holding it, up to the area holding them."
        case .top: "The element hit, then each holding it, to the top of its tree."
        case .short(.unanswered):
            rows == 0 ? "The element hit would not say what it is." : "Stopped short: a read did not answer, so what holds the last row is unknown."
        case .short(.overTime):
            rows == 0 ? "The time for hit tests ran out before the element hit was read." : "Stopped short: the time for hit tests ran out, so what holds the last row is unknown."
        }
    }

    /// One element: role, frame, then each text it said, and how many would not say.
    /// Tab-separated, like every row eyes prints.
    private static func row(_ element: Landing.Element) -> String {
        ([element.role.rawValue, element.frame.map(String.init(describing:)) ?? "(no frame)"] + element.texts.map(spelled)
            + (element.unanswered > 0 ? ["(\(element.unanswered) of its texts unanswered)"] : []))
            .joined(separator: "\t")
    }

    /// The most of one text a row prints: a control's name whole, never a terminal's or a
    /// document's whole contents, which is a text area's value.
    static let longest = 120

    /// A text on one line - a row is one element - its whitespace runs, newlines and tabs
    /// among them, as one space, and cut past `longest` saying how long it was, so a cut text
    /// is never taken for a whole one. [LAW:no-silent-failure]
    static func spelled(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > longest ? "\(line.prefix(longest))... (\(line.count) characters)" : line
    }

    /// The hit test and the window server, in the process. The window is looked for in the
    /// listing read before the climb, so it and the front look it is judged by are one moment.
    @MainActor
    static func land(at point: ScreenPoint) async throws -> Landing? {
        guard Geometry.displays().contains(where: { $0.frame.contains(point) }) else { throw NoSuchPlace.pointOffScreen(point) }
        let listing = try Geometry.onScreen()
        guard let climb = try await TreeReader(granted: SourceKind.granted).climb(from: point, until: .now + hitTesting) else { return nil }
        let own = try await Front.Passed.current()
        // No front is an answer here, not a refusal: a hit on the app eyes answers to, with
        // nothing else on screen, is the case most worth saying.
        let front: Front?
        do { front = try Front.now(own: own, listing: listing) } catch { front = nil }
        let window = listing.windows.first { $0.pid == climb.pid && $0.frame.contains(point) }
        let name = NSRunningApplication(processIdentifier: climb.pid)?.localizedName ?? window?.owner
        return Landing(point: point, app: Front.App(pid: climb.pid, name: name),
                       standing: Front.standing(of: climb.pid, own: own, front: front, in: listing, hit: { TreeReader.hit($0) }),
                       window: window, elements: climb.elements, end: climb.end, calls: climb.calls)
    }
}

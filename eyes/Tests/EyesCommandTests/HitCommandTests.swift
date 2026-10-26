import Eyes
import Telemetry
import TelemetryTesting
import Testing
@testable import EyesCommand
@testable import Tree

/// What `eyes hit` says of a click at a point, asked with landings a test wrote.
@Suite(.eventsKept) struct HitCommandTests {
    static let settings = Front.App(pid: 300, name: "System Settings")
    static let window = Window(id: 4127, owner: "System Settings", pid: 300, frame: ScreenRect(x: 0, y: 25, width: 800, height: 600), layer: 0)
    static let add = Landing.Element(role: Role(rawValue: "AXButton"), texts: ["Add"], frame: ScreenRect(x: 160, y: 417, width: 18, height: 18))
    static let list = Landing.Element(role: Role(rawValue: "AXList"), texts: [], unanswered: 1, frame: nil)

    /// The case the epic began with: the button "Add" in System Settings, the front app.
    static let button = Landing(point: ScreenPoint(x: 169, y: 426.5), app: settings, standing: .front(settings), window: window,
                                elements: [add, list], end: .area, calls: 3, frontCalls: 1)

    /// The landings the MCP tests serve: the button at 1,1 and at 169,426.5, nothing at 2,2, no
    /// grant at 3,3 and a hit test that did not answer at 4,4.
    static let landings: Hit.Landings = { point in
        switch (point.x, point.y) {
        case (2, 2): return .nothing(calls: 1, window: nil)
        case (5, 5): return .nothing(calls: 1, window: window)
        case (3, 3): throw TreeError.noGrant
        case (4, 4): throw HitUnheard(point: point, why: .unanswered, calls: 1)
        default: return .landed(Landing(point: point, app: settings, standing: .front(settings), window: window, elements: [add, list], end: .area,
                                        calls: 3, frontCalls: 1))
        }
    }

    private func landing(_ standing: Standing, window: Window? = window, elements: [Landing.Element] = [add], end: Landing.End = .area) -> Landing {
        Landing(point: ScreenPoint(x: 169, y: 426), app: Self.settings, standing: standing, window: window, elements: elements, end: end, calls: 2, frontCalls: 0)
    }

    /// The scope line names the app, where it stands, the window by the id `find --window`
    /// takes, and how the climb ended; then a row per element, its texts and what would not say.
    @Test func aLandingSaysTheAppTheWindowAndEachElement() {
        #expect(Hit.report(at: Self.button.point, .landed(Self.button)) == """
            A click at 169,426.5 lands in System Settings (pid 300), the front app, which a look with no place named reads, \
            in its window 4127 at 0,25,800,600. The element hit, then each holding it, up to the area holding them. \
            Each row: role, frame as x,y,width,height in vhid click coordinates, then what it says.
            AXButton\t160,417,18,18\tAdd
            AXList\t(no frame)\t(1 of its texts unanswered)
            """)
    }

    /// Each standing is said apart: the agent's own terminal and an app behind are the clicks
    /// an agent most needs to hear about before making them.
    @Test func whereTheAppStandsIsSaid() {
        let said = { (s: Standing) in Hit.report(at: ScreenPoint(x: 169, y: 426), .landed(landing(s))) }
        let panel = Front.App(pid: 900, name: "Open and Save Panel Service")
        #expect(said(.overFront(Self.settings)).contains("a window over the front app System Settings (pid 300), which a look with no place named reads too"))
        #expect(said(.own("iTerm2")).contains("the app eyes answers to, whose windows a look never reads: the agent's own terminal or app"))
        #expect(said(.behind(panel)).contains("not in front: a look with no place named reads Open and Save Panel Service (pid 900)"))
        #expect(said(.behind(nil)).contains("not in front: only the app eyes answers to has an ordinary window open, so a look with no place named has no app to read"))
        #expect(said(.noWindow(Self.settings)).contains("in no window of its own here - a menu bar, a menu - which a look with no place named never reads"))
        #expect(said(.otherDisplay(Self.settings, 1)).contains(
            "on a display a look with no place named does not read: it reads System Settings (pid 300) on display 1"))
        #expect(Hit.report(at: ScreenPoint(x: 1, y: 1), .landed(landing(.front(Self.settings), window: nil))).contains("in none of its listed windows"))
    }

    /// A climb that stopped short says what is unknown, never as a whole answer.
    @Test func howTheClimbEndedIsSaid() {
        let ended = { (end: Landing.End, elements: [Landing.Element]) in
            Hit.report(at: ScreenPoint(x: 1, y: 1), .landed(landing(.front(Self.settings), elements: elements, end: end)))
        }
        #expect(ended(.top, [Self.add]).contains("to the top of its tree"))
        #expect(ended(.short(.unanswered), [Self.add]).contains("Stopped short: a read did not answer, so what holds the last row is unknown."))
        #expect(ended(.short(.overTime), [Self.add]).contains("Stopped short: the time for hit tests ran out"))
        #expect(ended(.short(.unanswered), []).contains("The element hit would not say what it is."))
        #expect(ended(.tooDeep, [Self.add]).contains("Stopped at 1 elements, every one answering: its parents run in a loop"))
        #expect(Hit.report(at: ScreenPoint(x: 2, y: 2), .nothing(calls: 1, window: nil))
            == "A click at 2,2 hits no element: the system's hit test answered that nothing is there, and no window is listed there.")
        // An app that exposes nothing at the point still draws there, and a click lands in it.
        #expect(Hit.report(at: ScreenPoint(x: 5, y: 5), .nothing(calls: 1, window: Self.window))
            == "A click at 5,5 hits no element the system's hit test can name, but lands in window 4127 of System Settings at 0,25,800,600,"
            + " the frontmost listed there: its app exposes nothing at that point.")
    }

    /// A row is one line: a text area's value - a terminal's whole scrollback - is one line,
    /// cut, saying how long it was.
    @Test func aLongOrManyLinedTextIsOneLineAndSaysItWasCut() {
        #expect(Hit.spelled("Save\tas…\n  PDF") == "Save as… PDF")
        let scrollback = String(repeating: "line\n", count: 100)
        let cut = Hit.spelled(scrollback)
        #expect(cut == String(repeating: "line ", count: 24) + "... (500 characters)")
        #expect(!cut.contains("\n"))
    }

    /// A point a shell hands over that is no place is refused before anything is asked.
    @Test func aPointThatIsNoPlaceIsRefused() throws {
        #expect(throws: (any Error).self) { try Hit.point(.infinity, 1) }
        #expect(throws: (any Error).self) { try Hit.point(1, .nan) }
        #expect(try Hit.point(-5, 10) == ScreenPoint(x: -5, y: 10))
        // A finite point past any screen is a number, said as one: it is refused off screen.
        #expect(ScreenPoint(x: 1e19, y: 0).description == "1e+19,0")
    }

    /// One `hit` event per question, with the app, where it stands, the window, the rows and
    /// calls, and how the climb ended - nothing there and a refusal are events too.
    /// [LAW:nothing-unseen]
    @Test func eachQuestionIsAnEvent() async throws {
        let events = Collected()
        try await Telemetry.$export.withValue(events.export) {
            _ = try await Hit.answer(at: ScreenPoint(x: 1, y: 1), landing: Self.landings)
            _ = try await Hit.answer(at: ScreenPoint(x: 2, y: 2), landing: Self.landings)
            _ = try? await Hit.answer(at: ScreenPoint(x: 4, y: 4), landing: Self.landings)
            _ = try await Hit.answer(at: ScreenPoint(x: 5, y: 5), landing: Self.landings)
        }
        let hits = events.all.filter { $0.event == "hit" }
        #expect(hits.map(\.outcome) == ["landed", "nothing", "error", "nothing"])
        #expect(hits[0].facts == ["app": "System Settings", "standing": "front", "front": "System Settings", "end": "area"])
        #expect(hits[0].counts == ["pid": 300, "window": 4127, "rows": 2, "calls": 3, "front_calls": 1])
        #expect(hits[1].facts == ["end": "nothing"])
        #expect(hits[1].counts == ["rows": 0, "calls": 1])
        #expect(hits[2].error?.contains("hit test at 4,4") == true)
        #expect(hits[2].facts == ["end": "unanswered"])
        #expect(hits[2].counts == ["rows": 0, "calls": 1])
        #expect(hits[3].counts == ["rows": 0, "calls": 1, "window": 4127])
    }
}

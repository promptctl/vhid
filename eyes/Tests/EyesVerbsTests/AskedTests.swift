import ArgumentParser
@testable import Seeing
import Synchronization
import Testing
@testable import EyesVerbs
import ScreenSpace
import ScreenSpaceTesting

/// What `look` answers, asked of a screen a test wrote: the arguments read into one question,
/// and the overview that shows the desk whatever the place came to.
@Suite(.eventsKept) @MainActor struct AskedTests {
    nonisolated static let main = Display(id: 1, frame: try! ScreenRect(x: 0, y: 0, width: 1512, height: 982), isMain: true, scale: 2)
    static let safari = Front.App(pid: 400, name: "Safari")
    static let finder = Front.App(pid: 500, name: "Finder")
    static let window = Window(id: 4, owner: "Safari", pid: 400, frame: try! ScreenRect(x: 0, y: 40, width: 600, height: 400), layer: 0)

    /// Finder frontmost over the desktop, Safari's window behind it.
    static let desk = Desk(frontmost: finder, own: Front.Passed(pids: [80], name: "iTerm2"),
                           running: [Desk.Running(app: safari, regular: true), Desk.Running(app: finder, regular: true)],
                           listing: WindowListing(windows: [window], excluded: []), layout: .at(main.frame), describe: { _ in main })

    nonisolated static let found = try! Found(text: Text("Reload")!, frame: try! ScreenRect(x: 20, y: 50, width: 40, height: 20), source: .tree(role: Role(rawValue: "AXButton"), also: []), on: .vast)

    /// A reader that reads `Reload` wherever it is asked, keeping the regions it was asked for.
    final class Reader: Sendable {
        private let regions = Mutex<[Region]>([])
        var asked: [Region] { regions.withLock { $0 } }
        func read(_ source: SourceKind, _ query: Query, _ layout: DisplayLayout) async throws -> Judged {
            regions.withLock { $0.append(query.region) }
            return Judged(Reading(outcome: .matched(Matches([AskedTests.found])!), scope: Scope(region: AskedTests.main.frame, examined: 1, reach: .whole))) { r, _ in r }
        }
    }

    static func asked(text: String? = nil, exact: Bool = false, until: Until? = nil, display: UInt32? = nil, app: String? = nil,
                      limit: Int? = nil, x: Double? = nil, y: Double? = nil) throws -> Asked {
        try Asked.parsed(text: text, exact: exact, edits: nil, near: nil, until: until, timeout: nil, display: display, window: nil,
                         page: nil, rect: nil, app: app, limit: limit, source: nil, role: nil, x: x, y: y, as: .argument)
    }

    /// The done criterion: no arguments answers with the displays, the windows, and the text
    /// of the app a person sees in front - Safari, behind a windowless Finder - with its points.
    @Test func noArgumentsAnswersTheDeskAndTheFrontAppsText() async throws {
        let reader = Reader()
        let said = try await Self.asked().answer(on: Screen(desk: { Self.desk }, read: reader.read))
        let parts = said.components(separatedBy: "\n\n")
        #expect(parts.count == 3)
        #expect(parts[0].hasPrefix("1 display, main first.") && parts[0].contains("1\tmain\t0,0,1512,982"))
        #expect(parts[1].hasPrefix("1 window, front to back") && parts[1].contains("Frontmost: Finder (pid 500), with no window listed."))
        #expect(parts[2].contains("1 matched") == false && parts[2].hasPrefix("1 run in Safari (pid 400) and what is in front of it, passing over Finder (pid 500), which has no window open, on display 1"))
        #expect(parts[2].contains("40,60\t20,50,40,20\tReload\tAXButton"))
        #expect(reader.asked == [.front(Front(app: Self.safari, display: 1, own: Self.desk.own, passedOver: .windowless(Self.finder)))])
    }

    /// The desk is answered when the place cannot be read, with why it could not be.
    @Test func aPlaceThatCannotBeReadStillAnswersTheDesk() async throws {
        let reader = Reader()
        let said = try await Self.asked(app: "Nope").answer(on: Screen(desk: { Self.desk }, read: reader.read))
        let parts = said.components(separatedBy: "\n\n")
        #expect(parts.count == 3)
        #expect(parts[0].hasPrefix("1 display") && parts[1].hasPrefix("1 window"))
        #expect(parts[2] == "No text was read: no running app is called \"Nope\", named exactly as it is listed; running: Finder, Safari.")
        #expect(reader.asked.isEmpty)
    }

    /// An app named is the app read, on the display holding its window.
    @Test func anAppNamedIsTheAppRead() async throws {
        let reader = Reader()
        _ = try await Self.asked(app: "Safari").answer(on: Screen(desk: { Self.desk }, read: reader.read))
        #expect(reader.asked == [.front(Front(app: Self.safari, display: 1, own: Self.desk.own, passedOver: nil))])
    }

    /// A look withdrawn while it reads is withdrawn, not answered as a place that could not be read.
    @Test func aLookCancelledWhileReadingIsCancelledNotAnswered() async {
        await #expect(throws: CancellationError.self) {
            _ = try await Self.asked().answer(on: Screen(desk: { Self.desk }, read: { _, _, _ in throw CancellationError() }))
        }
    }

    /// Text asks where it is, and answers alone, without the desk.
    @Test func textIsFoundAndAnsweredAlone() async throws {
        let said = try await Self.asked(text: "Reload", display: 1).answer(on: Screen(desk: { Self.desk }, read: Reader().read))
        #expect(said.hasPrefix("1 matched \"Reload\" in display 1"))
        #expect(!said.contains("display, main first"))
    }

    /// Each set of arguments that asks no one question is refused, naming them as given.
    @Test func argumentsThatAskNoOneQuestionAreRefused() {
        let refusal = { (asked: () throws -> Asked) -> String? in
            do { _ = try asked(); return nil } catch let refused as ValidationError { return refused.message } catch { return "\(error)" }
        }
        #expect(refusal { try Self.asked(x: 1) } == "give x and y together: the point a click would land on")
        #expect(refusal { try Self.asked(text: "OK", x: 1, y: 2) }
            == "x and y ask what a click there would land on, which takes nothing else, and text was given too")
        #expect(refusal { try Self.asked(exact: true, until: .present) } == "exact, until needs text, the text to find")
        #expect(refusal { try Self.asked(display: 1, app: "Safari") } == "give at most one of display, window, page, rect, app")
        #expect(refusal { try Self.asked(app: "") } == "app is empty, which names no app")
        #expect(refusal { try Self.asked(limit: 0) } == "limit must be at least 1")
    }

    @Test func aPointAsksWhatAClickThereLandsOn() throws {
        guard case .at(let point) = try Self.asked(x: -500, y: 300).question else { Issue.record("not a point"); return }
        #expect(point == (try! ScreenPoint(x: -500, y: 300)))
    }
}

import Grants
import Pixels
import Seeing
import Telemetry
import TelemetryTesting
import Testing
@testable import EyesVerbs
@testable import Tree

/// What a look asks and answers, over a screen a test wrote: the arguments through the
/// verbs' own rules, the answer as the verbs' own reports.
/// Serialized: the fake reader records into one shared `asked`.
@Suite(.serialized, .eventsKept) struct LookTests {
    static let listing = WindowListing(
        windows: [
            Window(id: 1, owner: "Safari", pid: 400, frame: ScreenRect(x: 0, y: 33, width: 1512, height: 949), layer: 0),
            Window(id: 2, owner: "Finder", pid: 401, frame: ScreenRect(x: -800, y: 0, width: 800, height: 600), layer: 0),
        ],
        excluded: [])
    static let frontmost = Front.App(pid: 401, name: "Finder")

    /// Every query the fake reader was handed, so a test can check what reached it.
    actor Asked {
        var queries: [Query] = []
        var sources: [SourceKind] = []
        func add(_ q: Query, _ s: SourceKind) { queries.append(q); sources.append(s) }
    }
    static let asked = Asked()

    /// A reader that sees one run, "Save", everywhere but the displays set aside below.
    static let read: @Sendable (SourceKind, Query) async throws -> Judged = { source, query in .standing(try await seen(source, query)) }
    static let seen: @Sendable (SourceKind, Query) async throws -> Reading = { source, query in
        await asked.add(query, source)
        if query.region == .display(666) { throw PixelsError.noGrant }
        if query.region == .display(667), source == .tree { throw TreeError.noGrant }
        if query.region == .display(669) {
            return Reading(outcome: .nearest([]), scope: Scope(region: ScreenRect(x: 0, y: 0, width: 10, height: 10), examined: 0,
                reach: .stopped(.merged(.blind(.tree, "\(TreeError.noGrant)", missingGrant: true), .read(.pixels, .whole)))))
        }
        if query.region == .display(670) {
            return Reading(outcome: .nearest([]), scope: Scope(region: ScreenRect(x: 0, y: 0, width: 10, height: 10), examined: 0,
                reach: .stopped(.merged(.read(.tree, .whole), .blind(.pixels, "\(PixelsError.noGrant)", missingGrant: true)))))
        }
        if query.region == .display(668) { throw BothBlind(first: TreeError.noGrant, second: PixelsError.noGrant) }
        let save = Found(text: Text("Save")!, frame: ScreenRect(x: -300, y: 40, width: 40, height: 20), source: .pixels(confidence: Confidence(1)!))
        return Reading(outcome: .matched(Matches([save])!), scope: Scope(region: ScreenRect(x: -1512, y: 316, width: 1512, height: 982), examined: 1, reach: .whole))
    }

    static let viewport = ScreenRect(x: 22, y: 190, width: 1200, height: 688)
    /// Window 219 shows one page, 220 two side by side, and 221's tree has no grant.
    static let pages: Where.Place.Pages = { id in
        switch id {
        case 219: return Paged(pages: [viewport], examined: 40, stop: nil)
        case 220: return Paged(pages: [viewport, viewport], examined: 52, stop: nil)
        default: throw TreeError.noGrant
        }
    }

    /// What is in front: System Settings, with the agent's own terminal passed over; Mail
    /// when it is named.
    static let systemSettings = Front(app: Front.App(pid: 300, name: "System Settings"), display: 1,
                                      own: Front.Passed(pids: [80], name: "iTerm2"), passedOver: true)
    static let mail = Front(app: Front.App(pid: 500, name: "Mail"), display: 1, own: Front.Passed(pids: [80], name: "iTerm2"), passedOver: false)
    static let fronts: Where.Place.Fronts = { which in
        switch which {
        case .inFront: systemSettings
        case .named("Mail"): mail
        case .named(let name): throw AppUnread(.notRunning(name, ordinary: ["Mail"]))
        }
    }

    static func screen(front: @escaping Where.Place.Fronts = fronts) -> Look.Screen {
        Look.Screen(listing: { listing }, frontmost: { frontmost }, displays: { DisplaysCommandTests.desk }, read: read,
                    pages: pages, front: front, landing: HitCommandTests.landings)
    }

    /// Every argument a look takes, each left out unless given.
    static func question(app: String? = nil, text: String? = nil, exact: Bool = false, edits: Int? = nil, near: String? = nil,
                         role: String? = nil, source: String? = nil, limit: Int? = nil, display: UInt32? = nil, window: UInt32? = nil,
                         page: UInt32? = nil, rect: String? = nil, x: Double? = nil, y: Double? = nil, until: String? = nil,
                         timeout: Double? = nil) throws -> Look.Question {
        try Look.question(app: app, text: text, exact: exact, edits: edits, near: near, role: role, source: source, limit: limit,
                          display: display, window: window, page: page, rect: rect, x: x, y: y, until: until, timeout: timeout, as: .argument)
    }

    static func answer(_ question: Look.Question, front: @escaping Where.Place.Fronts = fronts) async throws -> String {
        try await Look.answer(question, on: screen(front: front))
    }

    static func refusal(_ question: () throws -> Look.Question) -> String {
        do {
            _ = try question()
            return "not refused"
        } catch {
            return "\(error)"
        }
    }

    /// A look for no text in particular is the overview: the displays and windows, then
    /// the reading of the app in front. [LAW:one-source-of-truth]
    @Test func anOverviewLeadsWithTheDisplaysAndWindowsThenTheReading() async throws {
        let said = try await Self.answer(try Self.question())
        let query = Query(match: nil, region: .front(Self.systemSettings))
        #expect(said == [
            Displays.report(DisplaysCommandTests.desk),
            Windows.report(Self.listing, owner: nil, frontmost: Self.frontmost),
            try await Report.text(query, source: .merged, reading: Self.read),
        ].joined(separator: "\n\n"))
    }

    /// A look for a text answers with what the verb prints for the same query, and nothing
    /// of the desk: the arguments reach the reader through the verbs' own rules.
    @Test func aLookForTextAnswersWithTheVerbsReportAlone() async throws {
        for (question, query): (Look.Question, Query) in [
            (try Self.question(text: "save", display: 1), Query(match: .contains("save"), region: .display(1))),
            (try Self.question(text: "Save", exact: true, limit: 3, window: 9), Query(match: .exact("Save"), region: .window(9), limit: Limit(3)!)),
            (try Self.question(text: "Sabe", edits: 1, rect: "-400,0,200,100"),
             Query(match: .within(edits: Edits(1)!, of: "Sabe"), region: .rect(ScreenRect(x: -400, y: 0, width: 200, height: 100)))),
            (try Self.question(text: "save"), Query(match: .contains("save"), region: .front(Self.systemSettings))),
            (try Self.question(app: "Mail", text: "save"), Query(match: .contains("save"), region: .front(Self.mail))),
        ] {
            let said = try await Self.answer(question)
            #expect(await Self.asked.queries.last == query)
            #expect(await Self.asked.sources.last == .merged)
            #expect(said == (try await Report.text(query, source: .merged, reading: Self.read)))
        }
    }

    @Test func aLookReadsWithTheSourceGivenAndNamesIt() async throws {
        for kind in SourceKind.allCases {
            let said = try await Self.answer(try Self.question(text: "save", source: kind.rawValue, display: 1))
            #expect(await Self.asked.sources.last == kind)
            #expect(said.contains(kind.looked))
        }
    }

    /// x and y alone ask what a click there lands on, answered as the hit verb answers.
    @Test func aPointAnswersWithWhatAClickThereLandsOn() async throws {
        #expect(try await Self.answer(try Self.question(x: 169, y: 426.5)) == Hit.report(at: ScreenPoint(x: 169, y: 426.5), .landed(HitCommandTests.button)))
        #expect(try await Self.answer(try Self.question(x: 2, y: 2)) == Hit.report(at: ScreenPoint(x: 2, y: 2), .nothing(calls: 1, window: nil)))
        await #expect { try await Self.answer(try Self.question(x: 3, y: 3)) } throws: { "\($0)" == "\(TreeError.noGrant)" }
        await #expect { try await Self.answer(try Self.question(x: 4, y: 4)) } throws: {
            "\($0)" == "\(HitUnheard(point: ScreenPoint(x: 4, y: 4), why: .unanswered, calls: 1))"
        }
    }

    /// Each reader's missing grant, and a merge with neither, is a refusal naming the grant
    /// and the app that holds it, never an empty answer. [LAW:no-silent-failure] An overview
    /// still leads with the displays and windows, the places a caller can name instead.
    @Test func aMissingGrantIsARefusalNamingWhereItIsHeld() async throws {
        let picture = [Displays.report(DisplaysCommandTests.desk), Windows.report(Self.listing, owner: nil, frontmost: Self.frontmost)]
        for (question, expected): (Look.Question, [String]) in [
            (try Self.question(display: 668), picture + ["Neither reader could look. \(TreeError.noGrant) \(PixelsError.noGrant)"]),
            (try Self.question(source: "tree", display: 667), picture + ["\(TreeError.noGrant)"]),
            (try Self.question(display: 666), picture + ["\(PixelsError.noGrant)"]),
            (try Self.question(text: "Save", display: 666), ["\(PixelsError.noGrant)"]),
        ] {
            await #expect { try await Self.answer(question) } throws: { "\($0)" == expected.joined(separator: "\n\n") }
        }
    }

    /// A merge with one reader blind for want of a grant answers, and says where that grant is held.
    @Test func aMergeWithOneReaderBlindAnswersAndNamesWhereItsGrantIsHeld() async throws {
        let said = try await Self.answer(try Self.question(display: 669))
        #expect(said.contains("by pixels alone"))
        #expect(said.contains("tree could not look (\(TreeError.noGrant))"))
    }

    /// A wait answers with the report of the read it ended on, led by how the wait went;
    /// running out of time is an answer, not a refusal.
    @Test func aWaitSaysHowItWent() async throws {
        let settled = try await Self.answer(try Self.question(text: "Save", until: "present", timeout: 1))
        #expect(settled.hasPrefix("present after 1 read in "))
        #expect(settled.contains(": 1 matched \"Save\" in "))
        let timedOut = try await Self.answer(try Self.question(text: "Save", until: "absent", timeout: 0.3))
        #expect(timedOut.hasPrefix("timed out, not absent after "))
    }

    /// An absence a blind reader cannot prove is a refusal naming where its grant is held.
    @Test func anAbsenceWaitOnABlindReaderNamesWhereItsGrantIsHeld() async throws {
        await #expect { try await Self.answer(try Self.question(text: "Save", display: 670, until: "absent")) } throws: {
            "\($0)".hasPrefix("pixels could not look, so an absence cannot be proven") && "\($0)".contains("responsible for this process")
        }
    }

    /// A page is found through the tree's own search: its frame is the region read, and a
    /// window with two pages, or a tree with no grant, is refused as the verb refuses it.
    @Test func aPageIsReadWhereTheSearchFoundIt() async throws {
        _ = try await Self.answer(try Self.question(text: "Save", page: 219))
        #expect(await Self.asked.queries.last?.region == .page(window: 219, frame: Self.viewport))
        await #expect { try await Self.answer(try Self.question(text: "Save", page: 220)) } throws: { "\($0)".contains("2 web pages") }
        await #expect { try await Self.answer(try Self.question(page: 221)) } throws: { "\($0)".hasSuffix("\(TreeError.noGrant)") }
    }

    /// With nothing but the app eyes answers to on screen, a look naming no place is refused
    /// naming it, and an app named that is not running is refused naming those that are;
    /// either choice is its own event. [LAW:no-silent-failure]
    @Test func noAppToReadIsARefusalNamingWhy() async throws {
        let events = Collected()
        try await Telemetry.$export.withValue(events.export) {
            await #expect { try await Self.answer(try Self.question(text: "Save"), front: { _ in throw AppUnread(.onlyOwn("iTerm2")) }) } throws: {
                "\($0)" == "\(AppUnread(.onlyOwn("iTerm2")))"
            }
            await #expect { try await Self.answer(try Self.question(app: "Notes", text: "Save")) } throws: {
                "\($0)" == "\(AppUnread(.notRunning("Notes", ordinary: ["Mail"])))"
            }
            // An overview the app in front cannot be read for still lists the displays and
            // windows, the places a caller can name instead.
            await #expect { try await Self.answer(try Self.question(), front: { _ in throw AppUnread(.onlyOwn("iTerm2")) }) } throws: {
                "\($0)" == [Displays.report(DisplaysCommandTests.desk), Windows.report(Self.listing, owner: nil, frontmost: Self.frontmost),
                              "\(AppUnread(.onlyOwn("iTerm2")))"].joined(separator: "\n\n")
            }
        }
        #expect(events.all.filter { $0.event == "front" }.map(\.outcome) == ["error", "error", "error"])
    }

    /// What a look will not act on is refused in a caller's words, by the verbs' own rules.
    @Test func aLookRefusesWhatTheVerbsRefuse() {
        for (question, expected): (() throws -> Look.Question, String) in [
            ({ try Self.question(text: "  ") }, "the text to find is blank"),
            ({ try Self.question(text: "a", exact: true, edits: 1) }, "give exact or edits, not both"),
            ({ try Self.question(text: "a", edits: -1) }, "edits cannot be negative"),
            ({ try Self.question(text: "a", timeout: 5) }, "timeout needs until: it is how long to wait"),
            ({ try Self.question(text: "a", until: "gone") }, "until is gone, and it takes one of present, absent"),
            ({ try Self.question(text: "a", until: "absent", timeout: 0) }, "timeout is 0.0, and it takes seconds above 0 and at most \(Int(Wait.longest))"),
            ({ try Self.question(limit: 0) }, "limit must be at least 1"),
            ({ try Self.question(display: 1, window: 2) }, "give at most one of app, display, window, page, rect"),
            ({ try Self.question(app: "Mail", page: 2) }, "give at most one of app, display, window, page, rect"),
            ({ try Self.question(app: "") }, "app is empty, which names no app; leave it off to read the app in front"),
            ({ try Self.question(rect: "1,2,3") }, "rect wants \(ScreenRect.spelling) - got 1,2,3"),
            ({ try Self.question(source: "ocr") }, "source is ocr, and it takes one of tree, pixels, merged"),
            ({ try Self.question(role: " ") }, "the role to find is blank"),
            ({ try Self.question(text: "+", role: "AXButton", source: "pixels") }, "role needs the tree, and source pixels reads no roles: use tree or merged"),
            ({ try Self.question(text: "a", near: " ") }, "the text to find matches near is blank"),
            // The text's qualifiers need a text; a point needs both coordinates and nothing else.
            ({ try Self.question(exact: true) }, "give text, the text to find, for exact to qualify"),
            ({ try Self.question(until: "present", timeout: 2) }, "give text, the text to find, for until, timeout to qualify"),
            ({ try Self.question(x: 1) }, "give x and y together: the point a click would land on"),
            ({ try Self.question(text: "a", x: 1, y: 2) }, "x and y ask what a click there lands on, which nothing else narrows: give them without text"),
            ({ try Self.question(app: "Mail", near: "b", x: 1, y: 2) }, "x and y ask what a click there lands on, which nothing else narrows: give them without app, near"),
        ] {
            #expect(Self.refusal(question) == expected)
        }
    }
}

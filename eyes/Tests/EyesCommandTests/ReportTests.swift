import CoreGraphics
@testable import Eyes
import Pixels
import Telemetry
import TelemetryTesting
@testable import Tree
import Testing
@testable import EyesCommand

/// What `find` and `read` print, asked with a reading a test wrote.
@Suite(.eventsKept) struct ReportTests {
    static let display = ScreenRect(x: -2400, y: -300, width: 2400, height: 1600)

    private func found(_ text: String, x: Double) -> Found {
        Found(text: Text(text)!, frame: ScreenRect(x: x, y: -60, width: 40, height: 20), source: .pixels(confidence: Confidence(1)!))
    }

    /// The done criterion for an absence: it carries where it looked, how much it read,
    /// that it read all of it, and what was nearest - each nearest with how far off.
    @Test func anAbsenceSaysWhereItLookedHowMuchItReadAndWhatWasNear() {
        let query = Query(match: .contains("Settings"), region: .display(12))
        let reading = Reading(
            outcome: .nearest([Near(found: found("Setlings", x: -1900), distance: 1)]),
            scope: Scope(region: Self.display, examined: 47, excluded: [Exclusion(reason: .duplicate, count: 3)], reach: .whole)
        )
        #expect(Report.lines(reading, query: query, source: .pixels) == [
            "\"Settings\" not found in display 12 -2400,-300,2400,1600 by pixels; 47 runs read; 3 duplicate;"
                + " whole region read; nearest follow. Each row's point is its centre and its box holds it, x,y,width,height, in vhid click coordinates.",
            "-1880,-50\t-1900,-60,40,20\tSetlings\tpixels\t1 off",
        ])
    }

    /// A box cut and a box left unchecked are each said in the scope, so a row whose box is
    /// the app's claim is never taken for one checked against where a click lands.
    @Test func theScopeSaysWhichBoxesWereCutAndWhichUnchecked() {
        let query = Query(match: .contains("OK"), region: .display(12))
        func scope(_ boxes: Boxes) -> String {
            Report.scope(Reading(outcome: .nearest([]), scope: Scope(region: Self.display, examined: 4, reach: .whole, boxes: boxes)),
                         query: query, source: .tree)
        }
        #expect(scope(Boxes()).contains("4 runs read; whole region read."))
        #expect(scope(Boxes(narrowed: 1, calls: 30)).contains("4 runs read; 1 box cut to where a click presses it; whole region read."))
        #expect(scope(Boxes(narrowed: 2, unchecked: [.unanswered: 1, .overTime: 2])).contains(
            "4 runs read; 2 boxes cut to where a click presses it, 3 boxes unchecked (1 unanswered, 2 out of time); whole"))
        #expect(scope(Boxes(unchecked: [.elsewhere: 1])).contains("4 runs read; 1 box unchecked (1 its point on something else); whole"))
    }

    /// Each row says what it is: the tree's role, kept through a merge, or `pixels` for text
    /// only pixels saw - so a page's button is told from a bookmark of the same name.
    @Test func aRowNamesItsRole() {
        let frame = ScreenRect(x: 0, y: 0, width: 40, height: 20)
        let button = Source.tree(role: Role(rawValue: "AXButton"), also: [])
        let rows = Report.rows(.matched(Matches([
            Found(text: Text("Settings")!, frame: frame, source: .tree(role: Role(rawValue: "AXLink"), also: [])),
            Found(text: Text("Settings")!, frame: frame, source: .merged(button, .pixels(confidence: Confidence(1)!))),
            Found(text: Text("Canvas")!, frame: frame, source: .pixels(confidence: Confidence(1)!)),
        ])!))
        #expect(rows == ["20,10\t0,0,40,20\tSettings\tAXLink", "20,10\t0,0,40,20\tSettings\tAXButton", "20,10\t0,0,40,20\tCanvas\tpixels"])
    }

    /// A row keeps the text its element shows and then says what else the element says in
    /// words, each after its attribute: the "+" button found as "Add" still reads "+".
    @Test func aRowSaysWhatElseItsElementSays() {
        let frame = ScreenRect(x: 160, y: 417, width: 18, height: 18)
        let plus = Found(text: Text("+")!, frame: frame, source: .tree(role: Role(rawValue: "AXButton"), also: [Words(.description, Text("Add")!)]))
        #expect(Report.rows(.matched(Matches([plus])!)) == ["169,426\t160,417,18,18\t+\tAXButton\tdescription Add"])
        let reading = Reading(outcome: .matched(Matches([plus])!), scope: Scope(region: frame, examined: 1, reach: .whole))
        #expect(Report.scope(reading, query: Query(match: .contains("Add"), region: .rect(frame), role: Role(rawValue: "AXButton")), source: .tree)
            .hasPrefix("1 matched \"Add\" as AXButton in rect"))
        #expect(Report.scope(reading, query: Query(match: nil, region: .rect(frame), role: Role(rawValue: "AXButton")), source: .tree)
            .hasPrefix("1 run as AXButton in rect"))
        let unanchored = Reading(outcome: .unanchored([]), scope: Scope(region: frame, examined: 1, reach: .whole))
        #expect(Report.scope(unanchored, query: Query(match: .contains("Add"), region: .rect(frame), near: .contains("Row7"), role: Role(rawValue: "AXButton")),
                             source: .tree).hasPrefix("\"Row7\" not found to place \"Add\" as AXButton near"))
    }

    /// Every text a row prints is on one line, so a row is one element; a near miss says how
    /// far off it was in the column after its role, whatever else its element says.
    @Test func aRowsTextsAreSpelledOnOneLineAndItsDistanceStaysPut() {
        let frame = ScreenRect(x: 160, y: 417, width: 18, height: 18)
        let close = Found(text: Text("x")!, frame: frame, source: .tree(role: Role(rawValue: "AXImage"), also: [Words(.description, Text("Close\n(Esc)")!)]))
        #expect(Report.rows(.nearest([Near(found: close, distance: 2)])) == ["169,426\t160,417,18,18\tx\tAXImage\t2 off\tdescription Close (Esc)"])
    }

    /// A look notes the role it asked for and counts the rows matched by another of their
    /// element's words than the one they show.
    @Test func aLookNotesItsRoleAndCountsMatchesByOtherWords() async throws {
        let events = Collected()
        let frame = ScreenRect(x: 160, y: 417, width: 18, height: 18)
        let plus = Found(text: Text("+")!, frame: frame, source: .tree(role: Role(rawValue: "AXButton"), also: [Words(.description, Text("Add")!)]))
        let add = Found(text: Text("Add")!, frame: ScreenRect(x: 0, y: 0, width: 30, height: 18), source: .tree(role: Role(rawValue: "AXButton"), also: []))
        let reading = Reading(outcome: .matched(Matches([plus, add])!), scope: Scope(region: frame, examined: 2, reach: .whole))
        _ = try await Telemetry.$export.withValue(events.export) {
            try await Report.text(Query(match: .contains("Add"), region: .rect(frame), role: Role(rawValue: "AXButton")), source: .tree) { _, _ in .standing(reading) }
        }
        #expect(events.all.first?.facts["role"] == "AXButton")
        #expect(events.all.first?.counts["matched"] == 2)
        #expect(events.all.first?.counts["matched_also"] == 1)
    }

    /// The verbs refuse a blank role, and a role asked of pixels, which read none.
    @Test func aRoleIsRefusedBlankOrOfPixels() throws {
        #expect(try Find.parse(["Add", "--role", "AXButton"]).role == "AXButton")
        #expect(throws: (any Error).self) { try Find.parse(["Add", "--role", " "]) }
        #expect(throws: (any Error).self) { try Find.parse(["Add", "--role", "AXButton", "--source", "pixels"]) }
        #expect(throws: (any Error).self) { try Read.parse(["--role", "AXButton", "--source", "pixels"]) }
    }

    /// A row's box covers its frame in whole points, takes the form `rect` takes, and holds
    /// the centre printed beside it - fractional frames and negative coordinates included,
    /// where rounding each number its own way would cut the frame or miss the centre, and
    /// a frame narrower than a point, whose rounded centre falls on its right edge.
    @Test(arguments: [
        (ScreenRect(x: 10.4, y: 20.6, width: 80.3, height: 23.9), "10,20,81,25"),
        (ScreenRect(x: -1900.7, y: -60.2, width: 40.5, height: 19.4), "-1901,-61,41,21"),
        (ScreenRect(x: 0, y: 0, width: 40, height: 20), "0,0,40,20"),
        (ScreenRect(x: 10.9, y: 20, width: 10, height: 10), "10,20,11,10"),
        (ScreenRect(x: 10.5, y: 20, width: 0.4, height: 10), "10,20,2,10"),
    ])
    func aRowsBoxHoldsItsFrameAndItsCentre(frame: ScreenRect, box: String) throws {
        let found = Found(text: Text("Save")!, frame: frame, source: .tree(role: Role(rawValue: "AXButton"), also: []))
        let columns = try #require(Report.rows(.matched(Matches([found])!)).first).split(separator: "\t").map(String.init)
        #expect(columns[1] == box)
        let c = columns[0].split(separator: ",").compactMap { Double($0) }
        let printed = try #require(try printedRects(columns.joined(separator: "\t")).first).cgRect
        #expect(printed.contains(frame.cgRect))
        #expect(printed.contains(CGPoint(x: c[0], y: c[1])))
        #expect(try Find.parse(["Save", "--rect", columns[1]]).place.rect == columns[1])
    }

    /// The scope says a match was ordered beside other text, and that a page was read.
    @Test func theScopeNamesTheNearTextAndThePage() {
        let page = ScreenRect(x: 22, y: 190, width: 1200, height: 688)
        let reading = Reading(outcome: .matched(Matches([found("Remove", x: 100)])!), scope: Scope(region: page, examined: 9, reach: .whole))
        let query = Query(match: .contains("Remove"), region: .page(window: 219, frame: page), near: .contains("Beta"))
        #expect(Report.scope(reading, query: query, source: .tree)
            .hasPrefix("1 matched \"Remove\" near \"Beta\" in the page in window 219 22,190,1200,688 by the tree;"))
    }

    /// A blank region promises no rows it does not print.
    @Test func aBlankRegionPromisesNoNearest() {
        let reading = Reading(outcome: .nearest([]), scope: Scope(region: Self.display, examined: 0, reach: .whole))
        let lines = Report.lines(reading, query: Query(match: .exact("OK"), region: .display(12)), source: .tree)
        #expect(lines.count == 1)
        #expect(!lines[0].contains("nearest"))
        #expect(lines[0].hasPrefix("exactly \"OK\" not found"))
    }

    /// A cut answer says it was cut, so the rows are never taken for all there was.
    @Test func aCutReadingSaysItStoppedAtTheLimit() {
        let reading = Reading(
            outcome: .matched(Matches([found("a", x: -2000)])!),
            scope: Scope(region: Self.display, examined: 9, excluded: [Exclusion(reason: .ranked, count: 8)],
                         reach: .stopped(.resultLimit(Limit(1)!)))
        )
        let line = Report.scope(reading, query: Query(match: nil, region: .display(12), limit: Limit(1)!), source: .tree)
        #expect(line.hasPrefix("1 run in display 12"))
        #expect(line.contains("8 ranked; stopped at the limit of 1"))
    }

    /// A read that stopped short says so in its first words, where a caller acting on a
    /// match or an absence reads, whatever it ended in; a cut answer read the whole region.
    @Test func aPartialReadSaysSoInItsFirstWords() {
        let query = Query(match: .contains("Add"), region: .display(12))
        func head(_ outcome: Outcome, _ reach: Reach, near: Match? = nil) -> String {
            let line = Report.scope(Reading(outcome: outcome, scope: Scope(region: Self.display, examined: 3, reach: reach)),
                                    query: Query(match: query.match, region: query.region, near: near), source: .tree)
            return String(line.prefix { $0 != ";" })
        }
        let matched = Outcome.matched(Matches([found("Add", x: -2000)])!)
        let partial = " in the part read of display 12 -2400,-300,2400,1600 by the tree"
        #expect(head(matched, .stopped(.timeBudget(.seconds(5)))) == "1 matched \"Add\"" + partial)
        #expect(head(.nearest([]), .stopped(.unread)) == "\"Add\" not found" + partial)
        #expect(head(.unanchored([]), .stopped(.elementLimit(Limit(10)!)), near: .contains("Beta"))
            == "\"Beta\" not found to place \"Add\" near" + partial)
        #expect(head(.nearest([]), .stopped(.merged(.read(.tree, .whole), .read(.pixels, .stopped(.unread)))))
            .hasPrefix("\"Add\" not found in the part read of display 12"))
        #expect(head(matched, .stopped(.resultLimit(Limit(1)!))) == "1 matched \"Add\" in display 12 -2400,-300,2400,1600 by the tree")
        #expect(head(.nearest([]), .whole) == "\"Add\" not found in display 12 -2400,-300,2400,1600 by the tree")
    }

    /// A merge that did not read whole names each reader's reach, a blind one on one line,
    /// so an absence it cannot prove is never printed as one.
    @Test func aMergedReadingNamesEachReadersReach() {
        let reading = Reading(
            outcome: .nearest([]),
            scope: Scope(region: Self.display, examined: 5,
                         reach: .stopped(.merged(.blind(.tree, "no grant\nask again", missingGrant: false), .read(.pixels, .whole))))
        )
        let line = Report.scope(reading, query: Query(match: .exact("OK"), region: .display(12)), source: .merged)
        #expect(line.contains("tree could not look (no grant ask again), pixels whole region read"))
        #expect(line.contains("by pixels alone;"))
        #expect(!line.contains("\n"))
    }

    /// The scope line names which reader looked, for every reader there is.
    @Test(arguments: [(SourceKind.tree, "by the tree"), (.pixels, "by pixels"), (.merged, "by tree and pixels, merged")])
    func theScopeNamesWhoLooked(source: SourceKind, named: String) throws {
        let reading = Reading(outcome: .nearest([]), scope: Scope(region: Self.display, examined: 0, reach: .whole))
        let line = Report.scope(reading, query: Query(match: nil, region: .display(12)), source: source)
        #expect(line.hasPrefix("no text in display 12 -2400,-300,2400,1600 \(named);"))
        #expect(try printedRects(line) == [Self.display])
    }

    /// Both verbs take every source by name, merged when none is given, and refuse any other.
    @Test func theVerbsTakeEverySource() throws {
        for kind in SourceKind.allCases {
            #expect(try Find.parse(["OK", "--source", kind.rawValue]).source == kind)
            #expect(try Read.parse(["--source", kind.rawValue]).source == kind)
        }
        #expect(try Find.parse(["OK"]).source == .merged)
        #expect(try Read.parse([]).source == .merged)
        #expect(throws: (any Error).self) { try Read.parse(["--source", "ocr"]) }
    }

    /// Each kind names the reader that runs, and merged asks the tree first, so its exact
    /// frames and roles are the ones kept.
    @MainActor @Test func eachSourceIsTheReaderOfThatKind() throws {
        for kind in SourceKind.allCases { #expect(kind.reader.source == kind) }
        let merged = try #require(SourceKind.merged.reader as? MergedReader)
        #expect(merged.first.source == .tree)
        #expect(merged.second.source == .pixels)
    }

    /// Every look is one event: which reader, how it ended, and its counts, zeros included.
    @Test func aLookIsOneEvent() async throws {
        let events = Collected()
        let near = Reading(outcome: .nearest([]), scope: Scope(region: Self.display, examined: 5, excluded: [Exclusion(reason: .outside, count: 3)],
                                                               reach: .stopped(.timeBudget(.seconds(5)))))
        let hit = Reading(outcome: .matched(Matches([found("OK", x: -100)])!),
                          scope: Scope(region: Self.display, examined: 9, reach: .whole, boxes: Boxes(narrowed: 1, unchecked: [.elsewhere: 2], calls: 41)))
        let halfBlind = Reading(outcome: hit.outcome, scope: Scope(region: Self.display, examined: 9, reach: .stopped(.merged(
            .blind(.tree, "no grant", missingGrant: true), .read(.pixels, .stopped(.timeBudget(.seconds(5))))))))
        try await Telemetry.$export.withValue(events.export) {
            _ = try await Report.text(Query(match: .contains("OK"), region: .display(12)), source: .tree) { _, _ in .standing(near) }
            _ = try await Report.text(Query(match: .contains("OK"), region: .display(12)), source: .pixels,
                                      wait: Wait(until: .present, seconds: 1)) { _, _ in
                Judged(hit) { reading, _ in try await Task.sleep(for: .milliseconds(20)); return reading }
            }
            _ = try? await Report.text(Query(match: nil, region: .display(12)), source: .merged) { _, _ in throw PixelsError.noGrant }
            _ = try await Report.text(Query(match: .contains("OK"), region: .page(window: 7, frame: Self.display), near: .contains("Beta")),
                                      source: .merged) { _, _ in .standing(halfBlind) }
        }
        let seen = events.all
        #expect(seen.map(\.event) == ["look", "look", "look", "look"])
        #expect(seen.map(\.outcome) == ["not_matched", "settled", "error", "matched"])
        #expect(seen.map { $0.facts["source"] } == ["tree", "pixels", "merged", "merged"])
        #expect(seen.map { $0.facts["region"] } == ["display", "display", "display", "page"])
        #expect(seen.map { $0.facts["order"] } == ["reading", "reading", "reading", "near"])
        #expect(seen.map { $0.facts["role"] } == ["none", "none", "none", "none"])
        // A merge names each reader's reach, so a missing grant is told apart from a time budget.
        #expect(seen.map { $0.facts["reach"] } == ["time_budget", "whole", nil, "tree_blind+pixels_time_budget"])
        // Every reason an exclusion can have, zeros included.
        let none = Dictionary(uniqueKeysWithValues: Exclusion.Reason.allCases.map { ("excluded_\($0.rawValue)", 0) })
        #expect(seen[0].counts == none.merging(["excluded_outside": 3]) { $1 }.merging(
            ["reads": 1, "examined": 5, "matched": 0, "matched_also": 0, "nearest": 0, "boxes_narrowed": 0, "boxes_unchecked_unanswered": 0,
             "boxes_unchecked_elsewhere": 0, "boxes_unchecked_over_time": 0, "box_calls": 0, "box_ms": 0]) { $1 })
        #expect(seen[1].counts.filter { $0.key != "box_ms" } == none.merging(
            ["reads": 1, "examined": 9, "matched": 1, "matched_also": 0, "nearest": 0, "boxes_narrowed": 1,
             "boxes_unchecked_unanswered": 0, "boxes_unchecked_elsewhere": 2, "boxes_unchecked_over_time": 0, "box_calls": 41]) { $1 })
        #expect((seen[1].counts["box_ms"] ?? 0) >= 20)
        #expect(seen[1].facts["until"] == "present")
        #expect(seen[2].error != nil && seen[2].counts == ["reads": 1, "box_ms": 0])
    }

    /// A look at what is in front names the app it read and the one it passed over, and its
    /// event counts the processes whose windows it took in.
    @Test func aFrontLookNamesItsAppAndCountsItsOwners() async throws {
        let events = Collected()
        let front = Front(app: Front.App(pid: 300, name: "System Settings"), display: 2, own: Front.Passed(pids: [80], name: "iTerm2"), passedOver: true)
        let reading = Reading(outcome: .nearest([]), scope: Scope(region: Self.display, examined: 3, reach: .whole, owners: .only([300, 900])))
        let text = try await Telemetry.$export.withValue(events.export) {
            try await Report.text(Query(match: .contains("Add"), region: .front(front)), source: .tree) { _, _ in .standing(reading) }
        }
        #expect(text.hasPrefix("\"Add\" not found in System Settings (pid 300) and what is in front of it, passing over iTerm2,"
            + " which eyes answers to, on display 2 -2400,-300,2400,1600 by the tree; 3 runs read;"))
        #expect(events.all.first?.facts["region"] == "front")
        #expect(events.all.first?.counts["owners"] == 2)
        // A display read takes in every process, which no count stands for.
        let display = Reading(outcome: .nearest([]), scope: Scope(region: Self.display, examined: 3, reach: .whole))
        _ = try await Telemetry.$export.withValue(events.export) {
            try await Report.text(Query(match: .contains("Add"), region: .display(2)), source: .tree) { _, _ in .standing(display) }
        }
        #expect(events.all.last?.counts["owners"] == nil)
    }

    /// Choosing what is in front is its own event: the app, its pid, the display, and the
    /// app passed over.
    @Test func choosingWhatIsInFrontIsOneEvent() async throws {
        let events = Collected()
        let front = Front(app: Front.App(pid: 300, name: "System Settings"), display: 2, own: Front.Passed(pids: [80], name: "iTerm2"), passedOver: true)
        let region = try await Telemetry.$export.withValue(events.export) {
            try await Where.Place.front.region(front: { front })
        }
        #expect(region == .front(front))
        let event = try #require(events.all.first)
        #expect(event.event == "front")
        #expect(event.facts["front_app"] == "System Settings" && event.facts["passed_over"] == "iTerm2")
        #expect(event.counts["front_pid"] == 300 && event.counts["display"] == 2 && event.counts["own_pids"] == 1)
    }

    @Test func namingNoPlaceReadsWhatIsInFront() throws {
        guard case .front = try Where.place(display: nil, window: nil, page: nil, rect: nil, as: .flag) else {
            Issue.record("no place named is not the front"); return
        }
        guard case .region(.display(4)) = try Where.place(display: 4, window: nil, page: nil, rect: nil, as: .flag) else {
            Issue.record("a display named is not that display"); return
        }
    }

    /// Matches whose anchor is missing say which text was not found - the one the rows are
    /// near misses of - and their look ends unanchored, apart from not matched.
    @Test func anUnanchoredLookNamesTheAnchorAndSaysSo() async throws {
        let events = Collected()
        let beta = Near(found: found("Beta", x: 52), distance: 1)
        let unanchored = Reading(outcome: .unanchored([beta]), scope: Scope(region: Self.display, examined: 6, reach: .whole))
        let query = Query(match: .exact("Remove"), region: .display(12), near: .contains("Bta"))
        let text = try await Telemetry.$export.withValue(events.export) {
            try await Report.text(query, source: .tree) { _, _ in .standing(unanchored) }
        }
        #expect(text.hasPrefix("\"Bta\" not found to place exactly \"Remove\" near in "))
        #expect(text.contains("nearest follow"))
        #expect(events.all.map(\.outcome) == ["unanchored"])
        #expect(events.all.first?.counts["nearest"] == 1)
    }

    /// Finding a page is one event of its own, found or not: how much it read, how many
    /// pages it saw, and how far it got.
    @MainActor @Test func findingAPageIsOneEvent() async throws {
        let events = Collected()
        let viewport = ScreenRect(x: 22, y: 190, width: 1200, height: 688)
        try await Telemetry.$export.withValue(events.export) {
            let found = try await Where.Place.page(219).region { _ in Paged(pages: [viewport], examined: 40, stop: nil) }
            #expect(found == .page(window: 219, frame: viewport))
            _ = try? await Where.Place.page(219).region { _ in Paged(pages: [viewport, viewport], examined: 52, stop: nil) }
            _ = try? await Where.Place.page(219).region { _ in Paged(pages: [], examined: 4000, stop: .elementLimit(Limit(4000)!)) }
        }
        let seen = events.all
        #expect(seen.map(\.event) == ["page", "page", "page"])
        #expect(seen.map(\.outcome) == ["ok", "error", "error"])
        #expect(seen.map(\.counts) == [["examined": 40, "pages": 1], ["examined": 52, "pages": 2], ["examined": 4000, "pages": 0]])
        #expect(seen.map { $0.facts["reach"] } == ["whole", "whole", "element_limit"])
        #expect(seen[1].error?.contains("2 web pages") == true)
    }
}

extension Judged {
    /// A reading whose boxes stand as its reader placed them, as a fake reader's do.
    static func standing(_ reading: Reading) -> Judged { Judged(reading) { r, _ in r } }
}

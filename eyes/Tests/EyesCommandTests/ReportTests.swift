@testable import Eyes
import Pixels
import Synchronization
import Telemetry
import Testing
@testable import EyesCommand

/// What `find` and `read` print, asked with a reading a test wrote.
@Suite struct ReportTests {
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
            "\"Settings\" not found in display 12 -2400,-300 2400x1600 by pixels; 47 runs read; 3 duplicate;"
                + " whole region read; nearest follow. Points are centres, vhid click coordinates.",
            "-1880,-50\tSetlings\t1 off",
        ])
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
    func theScopeNamesWhoLooked(source: SourceKind, named: String) {
        let reading = Reading(outcome: .nearest([]), scope: Scope(region: Self.display, examined: 0, reach: .whole))
        let line = Report.scope(reading, query: Query(match: nil, region: .display(12)), source: source)
        #expect(line.hasPrefix("no text in display 12 -2400,-300 2400x1600 \(named);"))
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
        let events = Mutex<[Event]>([])
        let near = Reading(outcome: .nearest([]), scope: Scope(region: Self.display, examined: 5, reach: .whole))
        let hit = Reading(outcome: .matched(Matches([found("OK", x: -100)])!), scope: Scope(region: Self.display, examined: 9, reach: .whole))
        try await Telemetry.$export.withValue({ e in events.withLock { $0.append(e) } }) {
            _ = try await Report.text(Query(match: .contains("OK"), region: .display(12)), source: .tree) { _, _ in near }
            _ = try await Report.text(Query(match: .contains("OK"), region: .display(12)), source: .pixels,
                                      wait: Wait(until: .present, seconds: 1)) { _, _ in hit }
            _ = try? await Report.text(Query(match: nil, region: .display(12)), source: .merged) { _, _ in throw PixelsError.noGrant }
        }
        let seen = events.withLock { $0 }
        #expect(seen.map(\.event) == ["look", "look", "look"])
        #expect(seen.map(\.outcome) == ["not_matched", "settled", "error"])
        #expect(seen.map { $0.facts["source"] } == ["tree", "pixels", "merged"])
        #expect(seen[0].counts == ["reads": 1, "examined": 5, "matched": 0, "nearest": 0])
        #expect(seen[1].counts == ["reads": 1, "examined": 9, "matched": 1, "nearest": 0])
        #expect(seen[1].facts["until"] == "present")
        #expect(seen[2].error != nil)
    }
}

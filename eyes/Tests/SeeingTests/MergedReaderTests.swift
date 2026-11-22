import ScreenSpace
import ScreenSpaceTesting
import Testing
@testable import Seeing

/// A merged reader over two readers a test wrote, neither of which is the tree or pixels.
@MainActor @Suite struct MergedReaderTests {
    static let region = ScreenRect.at(0, 0, 1000, 800)

    struct Fake: Reader {
        let source: SourceKind
        let found: [Found]
        var reach = Reach.whole
        var fails = false
        var region = MergedReaderTests.region
        /// What this reader's check of a row's box finds.
        var press: @Sendable (Found) -> Pressed = { _ in .kept }
        var calls = 0

        struct Blind: Error, CustomStringConvertible { var description: String { "no grant" } }

        func look(_ query: Query, on layout: DisplayLayout) async throws -> Candidates {
            if fails { throw Blind() }
            return Candidates(found: found, region: region, examined: found.count, excluded: [], reach: reach, owners: .every)
        }

        func pressing(_ reading: Reading, until deadline: ContinuousClock.Instant) async throws -> Reading { reading.pressing { Checked(press($0), calls: calls) } }
    }

    /// A button the tree reports at `frame`.
    static func role(_ frame: ScreenRect, _ role: String = "AXButton") -> Source { .tree(role: Role(rawValue: role), frame: frame, also: []) }
    static let seen = Source.pixels(confidence: Confidence(0.8)!)

    /// A row as the `kind` reader places it, 20 points tall at `x`, `y`.
    private func at(_ text: String, _ x: Double, _ y: Double, _ kind: SourceKind, width: Double = 60, role: String = "AXButton") -> Found {
        let frame = ScreenRect.at(x, y, width, 20)
        return try! Found(text: Text(text)!, frame: frame, source: kind == .tree ? Self.role(frame, role) : Self.seen, within: Self.region, on: .vast)
    }

    /// The region resolved without asking the host which displays it has. [LAW:effects-at-boundaries]
    static let here: Locate = { _, _ in region }

    private func read(_ a: any Reader, _ b: any Reader, _ match: Match? = nil) async throws -> Reading {
        try await MergedReader(a, b, locate: Self.here).judged(Query(match: match, region: .rect(Self.region)), on: .vast).pressed()
    }

    private func all(_ reading: Reading) -> [Found] {
        guard case .matched(let m) = reading.outcome else { return [] }
        return m.all
    }

    @Test func disjointFindsAreAllReportedInReadingOrder() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Cancel", 10, 100, .tree)]),
            Fake(source: .pixels, found: [at("Chart title", 10, 10, .pixels)])
        )
        #expect(all(r).map(\.text.value) == ["Chart title", "Cancel"])
        #expect(r.scope.examined == 2)
        #expect(r.scope.excluded.isEmpty)
        #expect(r.scope.reach == .whole)
    }

    @Test func theSameTextAtOverlappingFramesIsOneFindWithBothSources() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Press Me", 100, 100, .tree)]),
            Fake(source: .pixels, found: [at("press me", 104, 102, .pixels, width: 55)])
        )
        let found = all(r)
        #expect(found.count == 1)
        #expect(found.first?.part == ScreenRect.at(100, 100, 60, 20))
        #expect(found.first?.source == .merged(Self.role(.at(100, 100, 60, 20)), Self.seen))
        #expect(found.first?.source.kind == .merged)
        #expect(r.scope.excluded == [Exclusion(reason: .duplicate, count: 1)])
    }

    @Test func theSameTextAtDifferentPlacesIsTwoFinds() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("OK", 100, 100, .tree)]),
            Fake(source: .pixels, found: [at("OK", 500, 600, .pixels)]),
            .exact("ok")
        )
        #expect(all(r).map(\.source) == [Self.role(.at(100, 100, 60, 20)), Self.seen])
        #expect(r.scope.excluded.isEmpty)
    }

    @Test func differentTextAtOverlappingFramesIsTwoFinds() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Save", 100, 100, .tree)]),
            Fake(source: .pixels, found: [at("Sve", 100, 100, .pixels)])
        )
        #expect(all(r).count == 2)
    }

    @Test func oneReaderThrowingNeverProvesAbsence() async throws {
        let r = try await read(
            Fake(source: .tree, found: [], fails: true),
            Fake(source: .pixels, found: [at("Elsewhere", 10, 10, .pixels)]),
            .exact("Allow")
        )
        #expect(!r.provesAbsence)
        #expect(r.scope.reach == .stopped(.merged(.blind(.tree, "no grant", missingGrant: false), .read(.pixels, .whole))))
        guard case .nearest(let near) = r.outcome else { Issue.record("\(r)"); return }
        #expect(near.map(\.found.text.value) == ["Elsewhere"])
    }

    @Test func oneReaderThrowingStillReportsWhatTheOtherFound() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Allow", 10, 10, .tree)]),
            Fake(source: .pixels, found: [], fails: true),
            .exact("Allow")
        )
        #expect(all(r).map(\.text.value) == ["Allow"])
        #expect(r.scope.reach == .stopped(.merged(.read(.tree, .whole), .blind(.pixels, "no grant", missingGrant: false))))
    }

    @Test func bothThrowingThrows() async {
        await #expect(throws: BothBlind.self) {
            try await read(Fake(source: .tree, found: [], fails: true), Fake(source: .pixels, found: [], fails: true))
        }
    }

    @Test func aReaderStoppedShortStopsTheMergeAndSaysWhich() async throws {
        let r = try await read(
            Fake(source: .tree, found: [], reach: .stopped(.unread)),
            Fake(source: .pixels, found: []),
            .exact("Allow")
        )
        #expect(!r.provesAbsence)
        #expect(r.scope.reach == .stopped(.merged(.read(.tree, .stopped(.unread)), .read(.pixels, .whole))))
    }

    @Test func bothWholeAndNothingMatchedProvesAbsence() async throws {
        let r = try await read(Fake(source: .tree, found: []), Fake(source: .pixels, found: []), .exact("Allow"))
        #expect(r.provesAbsence)
    }

    @Test func theMergedUnionIsCutToTheQueryLimit() async throws {
        let r = try await MergedReader(
            Fake(source: .tree, found: [at("a", 10, 10, .tree)]),
            Fake(source: .pixels, found: [at("b", 10, 200, .pixels)]),
            locate: Self.here
        ).judged(Query(match: nil, region: .rect(Self.region), limit: Limit(1)!), on: .vast).pressed()
        #expect(all(r).map(\.text.value) == ["a"])
        #expect(r.scope.reach == .stopped(.resultLimit(Limit(1)!)))
        #expect(r.scope.excluded == [Exclusion(reason: .ranked, count: 1)])
    }

    /// A run as Vision places it: each word at its own spot along one line, from `x`.
    private func run(_ text: String, _ x: Double, _ y: Double, within bound: ScreenRect = region) -> Found {
        let words = text.split(separator: " ").enumerated().map { i, w in
            Word(text: Text(String(w))!, frame: ScreenRect.at(x + Double(i) * 50, y, 45, 20))
        }
        return try! Found(first: words[0], rest: Array(words.dropFirst()), source: Self.seen, within: bound, on: .vast)
    }

    @Test func aContainsQueryFindsOneButtonOnceWhateverEachReaderDividedItInto() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Save As…", 100, 100, .tree, width: 95)]),
            Fake(source: .pixels, found: [run("Save As…", 100, 100)]),
            .contains("save")
        )
        #expect(all(r).count == 1)
        #expect(all(r).first?.source == .merged(Self.role(.at(100, 100, 95, 20)), Self.seen))
    }

    @Test func aRunCoveringSeveralElementsMergesWithEachAndKeepsTheRest() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Shell", 0, 0, .tree, width: 45), at("Edit", 50, 0, .tree, width: 45)]),
            Fake(source: .pixels, found: [run("Shell Edit View", 0, 0)])
        )
        #expect(all(r).map(\.text.value) == ["Shell", "Edit", "View"])
        #expect(all(r).map(\.source.kind) == [.merged, .merged, .pixels])
        #expect(r.scope.excluded == [Exclusion(reason: .duplicate, count: 2)])
    }

    /// A run half past its list's right edge, split where the tree's elements cover it: the
    /// word left over is placed as the run was, within its bound - its box the drawn part,
    /// its point inside the list.
    @Test func aMergesSplitKeepsTheRestWithinTheRunsBound() async throws {
        let list = ScreenRect.at(0, 0, 120, 20)
        let r = try await read(
            Fake(source: .tree, found: [at("Shell", 0, 0, .tree, width: 45), at("Edit", 50, 0, .tree, width: 45)]),
            Fake(source: .pixels, found: [run("Shell Edit View", 0, 0, within: list)])
        )
        let view = try #require(all(r).first { $0.text.value == "View" })
        #expect(view.part == .at(100, 0, 20, 20))
        #expect(list.contains(view.press))
    }

    @Test func aRecogniserSlipAtTheSamePlaceIsTheSameThing() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Allow", 100, 100, .tree)]),
            Fake(source: .pixels, found: [at("A1low", 100, 100, .pixels)]),
            .within(edits: Edits(1)!, of: "Allow")
        )
        #expect(all(r).map(\.text.value) == ["Allow"])
    }

    @Test func twoFindsOfTheSecondReaderAreNeverMergedWithEachOther() async throws {
        let r = try await read(
            Fake(source: .pixels, found: []),
            Fake(source: .tree, found: [at("OK", 100, 100, .tree), at("OK", 104, 102, .tree, role: "AXStaticText")])
        )
        #expect(all(r).map(\.source.kind) == [.tree, .tree])
        #expect(r.scope.excluded.isEmpty)
    }

    /// A stretch is the row seen again only where one of its own words meets the part the row
    /// shows: a row in the gap between two words says the same, and is another thing.
    @Test func aStretchMergesOnlyWhereOneOfItsWordsMeetsTheRow() async throws {
        let between = try await read(
            Fake(source: .tree, found: [at("Save As", 46, 0, .tree, width: 3)]),
            Fake(source: .pixels, found: [run("Save As", 0, 0)])
        )
        #expect(all(between).map(\.source.kind).sorted { "\($0)" < "\($1)" } == [.pixels, .tree])
        #expect(between.scope.excluded.isEmpty)
        let over = try await read(
            Fake(source: .tree, found: [at("Save As", 40, 0, .tree, width: 8)]),
            Fake(source: .pixels, found: [run("Save As", 0, 0)])
        )
        #expect(all(over).map(\.source.kind) == [.merged])
        #expect(over.scope.excluded == [Exclusion(reason: .duplicate, count: 1)])
    }

    /// Readers that looked at regions sharing no area have no place both looked, and the
    /// merge says so rather than naming one reader's region for both.
    @Test func readersThatLookedApartAreRefused() async {
        var apart = Fake(source: .pixels, found: [])
        apart.region = ScreenRect.at(2000, 0, 100, 100)
        await #expect(throws: ReadersApart.self) { try await read(Fake(source: .tree, found: []), apart) }
    }

    @Test func theRegionIsWhereBothLooked() async throws {
        var clipped = Fake(source: .pixels, found: [])
        clipped.region = ScreenRect.at(0, 0, 500, 800)
        let r = try await read(Fake(source: .tree, found: []), clipped)
        #expect(r.scope.region == ScreenRect.at(0, 0, 500, 800))
    }

    @Test func aWordOnlyTheSecondReaderSawIsNotCarriedAwayAsASlip() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Downloads", 0, 0, .tree, width: 95)]),
            Fake(source: .pixels, found: [run("Downloads 3", 0, 0)])
        )
        #expect(all(r).map(\.text.value) == ["Downloads", "3"])
        #expect(r.scope.excluded == [Exclusion(reason: .duplicate, count: 1)])
    }

    struct NoGrant: ReaderError { var missingGrant: Bool { true } }

    struct Refusing: Reader {
        let source = SourceKind.tree
        func look(_ query: Query, on layout: DisplayLayout) async throws -> Candidates { throw NoGrant() }
        func pressing(_ reading: Reading, until deadline: ContinuousClock.Instant) async throws -> Reading { reading }
    }

    @Test func aBlindReadersMissingGrantIsCarriedInItsPart() async throws {
        let r = try await MergedReader(Refusing(), Fake(source: .pixels, found: []), locate: Self.here).judged(Query(match: nil, region: .rect(Self.region)), on: .vast).pressed()
        guard case .stopped(.merged(.blind(.tree, _, let grant), _)) = r.scope.reach else { Issue.record("\(r)"); return }
        #expect(grant)
    }

    /// A reader whose place went away after the merge resolved it: a window closed between
    /// the two looks.
    struct Gone: Reader {
        let source = SourceKind.pixels
        func look(_ query: Query, on layout: DisplayLayout) async throws -> Candidates { throw NoSuchPlace.window(7) }
        func pressing(_ reading: Reading, until deadline: ContinuousClock.Instant) async throws -> Reading { reading }
    }

    @Test func aPlaceGoneBeforeOneReaderLookedIsThatReadersBlindness() async throws {
        let r = try await read(Fake(source: .tree, found: [at("Allow", 10, 10, .tree)]), Gone())
        #expect(all(r).map(\.text.value) == ["Allow"])
        guard case .stopped(.merged(.read(.tree, .whole), .blind(.pixels, _, false))) = r.scope.reach else { Issue.record("\(r)"); return }
    }

    struct Unasked: Reader {
        let source: SourceKind
        func look(_ query: Query, on layout: DisplayLayout) async throws -> Candidates {
            Issue.record("the \(source) reader was asked about a region that names nowhere")
            return Candidates(found: [], region: MergedReaderTests.region, examined: 0, excluded: [], reach: .whole, owners: .every)
        }
        func pressing(_ reading: Reading, until deadline: ContinuousClock.Instant) async throws -> Reading { reading }
    }

    /// Refused as the merge's answer even with both readers blind, so a bad id is never
    /// hidden behind a missing grant.
    @Test func aRegionThatNamesNowhereIsRefusedOnceBeforeEitherReader() async {
        let nowhere = NoSuchPlace.display(4_000_000_000)
        for (a, b) in [(Unasked(source: .tree), Unasked(source: .pixels)) as (any Reader, any Reader), (Refusing(), Refusing())] {
            await #expect {
                _ = try await MergedReader(a, b, locate: { _, _ in throw nowhere }).judged(Query(match: nil, region: .display(4_000_000_000)), on: .vast).pressed()
            } throws: { "\($0)" == nowhere.description }
        }
    }

    /// Each reader checks the rows it placed: the tree's cut stands, and the pixels reader,
    /// asked after it, sees the cut row and leaves it.
    @Test func eachReaderChecksTheBoxesOfTheRowsItPlaced() async throws {
        let cut = ScreenRect.at(17, 15, 40, 12)
        let tree = Fake(source: .tree, found: [at("Allow", 10, 10, .tree), at("Deny", 100, 10, .tree)],
                        press: { $0.text.value == "Allow" ? .narrowed(cut) : .unchecked(.elsewhere) }, calls: 4)
        let pixels = Fake(source: .pixels, found: [at("Allow", 12, 11, .pixels)],
                          press: { $0.source.role == nil ? .unchecked(.unanswered) : .kept })
        let r = try await read(tree, pixels)
        #expect(all(r).map(\.part) == [cut, ScreenRect.at(100, 10, 60, 20)])
        #expect(r.scope.boxes == Boxes(narrowed: 1, unchecked: [.elsewhere: 1], calls: 8))
    }
}

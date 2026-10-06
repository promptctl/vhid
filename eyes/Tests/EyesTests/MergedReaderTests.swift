import Testing
@testable import Eyes

/// A merged reader over two readers a test wrote, neither of which is the tree or pixels.
@MainActor @Suite struct MergedReaderTests {
    static let region = ScreenRect(x: 0, y: 0, width: 1000, height: 800)

    struct Fake: Reader {
        let source: SourceKind
        let found: [Found]
        var reach = Reach.whole
        var fails = false
        var region = MergedReaderTests.region
        /// What this reader's check of a row's box finds.
        var press: @Sendable (Found) -> Pressed = { _ in .kept }

        struct Blind: Error, CustomStringConvertible { var description: String { "no grant" } }

        func look(_ query: Query) async throws -> Candidates {
            if fails { throw Blind() }
            return Candidates(found: found, region: region, examined: found.count, excluded: [], reach: reach)
        }

        func pressing(_ reading: Reading) async throws -> Reading { reading.pressing(press) }
    }

    static let role = Source.tree(role: Role(rawValue: "AXButton"))
    static let seen = Source.pixels(confidence: Confidence(0.8)!)

    private func at(_ text: String, _ x: Double, _ y: Double, _ source: Source, width: Double = 60) -> Found {
        Found(text: Text(text)!, frame: ScreenRect(x: x, y: y, width: width, height: 20), source: source)
    }

    /// The region resolved without asking the host which displays it has. [LAW:effects-at-boundaries]
    static let here: Locate = { _ in region }

    private func read(_ a: any Reader, _ b: any Reader, _ match: Match? = nil) async throws -> Reading {
        try await MergedReader(a, b, locate: Self.here).read(Query(match: match, region: .rect(Self.region)))
    }

    private func all(_ reading: Reading) -> [Found] {
        guard case .matched(let m) = reading.outcome else { return [] }
        return m.all
    }

    @Test func disjointFindsAreAllReportedInReadingOrder() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Cancel", 10, 100, Self.role)]),
            Fake(source: .pixels, found: [at("Chart title", 10, 10, Self.seen)])
        )
        #expect(all(r).map(\.text.value) == ["Chart title", "Cancel"])
        #expect(r.scope.examined == 2)
        #expect(r.scope.excluded.isEmpty)
        #expect(r.scope.reach == .whole)
    }

    @Test func theSameTextAtOverlappingFramesIsOneFindWithBothSources() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Press Me", 100, 100, Self.role)]),
            Fake(source: .pixels, found: [at("press me", 104, 102, Self.seen, width: 55)])
        )
        let found = all(r)
        #expect(found.count == 1)
        #expect(found.first?.frame == ScreenRect(x: 100, y: 100, width: 60, height: 20))
        #expect(found.first?.source == .merged(Self.role, Self.seen))
        #expect(found.first?.source.kind == .merged)
        #expect(r.scope.excluded == [Exclusion(reason: .duplicate, count: 1)])
    }

    @Test func theSameTextAtDifferentPlacesIsTwoFinds() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("OK", 100, 100, Self.role)]),
            Fake(source: .pixels, found: [at("OK", 500, 600, Self.seen)]),
            .exact("ok")
        )
        #expect(all(r).map(\.source) == [Self.role, Self.seen])
        #expect(r.scope.excluded.isEmpty)
    }

    @Test func differentTextAtOverlappingFramesIsTwoFinds() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Save", 100, 100, Self.role)]),
            Fake(source: .pixels, found: [at("Sve", 100, 100, Self.seen)])
        )
        #expect(all(r).count == 2)
    }

    @Test func oneReaderThrowingNeverProvesAbsence() async throws {
        let r = try await read(
            Fake(source: .tree, found: [], fails: true),
            Fake(source: .pixels, found: [at("Elsewhere", 10, 10, Self.seen)]),
            .exact("Allow")
        )
        #expect(!r.provesAbsence)
        #expect(r.scope.reach == .stopped(.merged(.blind(.tree, "no grant", missingGrant: false), .read(.pixels, .whole))))
        guard case .nearest(let near) = r.outcome else { Issue.record("\(r)"); return }
        #expect(near.map(\.found.text.value) == ["Elsewhere"])
    }

    @Test func oneReaderThrowingStillReportsWhatTheOtherFound() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Allow", 10, 10, Self.role)]),
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
            Fake(source: .tree, found: [at("a", 10, 10, Self.role)]),
            Fake(source: .pixels, found: [at("b", 10, 200, Self.seen)]),
            locate: Self.here
        ).read(Query(match: nil, region: .rect(Self.region), limit: Limit(1)!))
        #expect(all(r).map(\.text.value) == ["a"])
        #expect(r.scope.reach == .stopped(.resultLimit(Limit(1)!)))
        #expect(r.scope.excluded == [Exclusion(reason: .ranked, count: 1)])
    }

    /// A run as Vision places it: each word at its own spot along one line, from `x`.
    private func run(_ text: String, _ x: Double, _ y: Double) -> Found {
        let words = text.split(separator: " ").enumerated().map { i, w in
            Word(text: Text(String(w))!, frame: ScreenRect(x: x + Double(i) * 50, y: y, width: 45, height: 20))
        }
        return Found(first: words[0], rest: Array(words.dropFirst()), source: Self.seen)
    }

    @Test func aContainsQueryFindsOneButtonOnceWhateverEachReaderDividedItInto() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Save As…", 100, 100, Self.role, width: 95)]),
            Fake(source: .pixels, found: [run("Save As…", 100, 100)]),
            .contains("save")
        )
        #expect(all(r).count == 1)
        #expect(all(r).first?.source == .merged(Self.role, Self.seen))
    }

    @Test func aRunCoveringSeveralElementsMergesWithEachAndKeepsTheRest() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Shell", 0, 0, Self.role, width: 45), at("Edit", 50, 0, Self.role, width: 45)]),
            Fake(source: .pixels, found: [run("Shell Edit View", 0, 0)])
        )
        #expect(all(r).map(\.text.value) == ["Shell", "Edit", "View"])
        #expect(all(r).map(\.source.kind) == [.merged, .merged, .pixels])
        #expect(r.scope.excluded == [Exclusion(reason: .duplicate, count: 2)])
    }

    @Test func aRecogniserSlipAtTheSamePlaceIsTheSameThing() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Allow", 100, 100, Self.role)]),
            Fake(source: .pixels, found: [at("A1low", 100, 100, Self.seen)]),
            .within(edits: Edits(1)!, of: "Allow")
        )
        #expect(all(r).map(\.text.value) == ["Allow"])
    }

    @Test func twoFindsOfTheSecondReaderAreNeverMergedWithEachOther() async throws {
        let r = try await read(
            Fake(source: .pixels, found: []),
            Fake(source: .tree, found: [at("OK", 100, 100, Self.role), at("OK", 104, 102, .tree(role: Role(rawValue: "AXStaticText")))])
        )
        #expect(all(r).map(\.source.kind) == [.tree, .tree])
        #expect(r.scope.excluded.isEmpty)
    }

    @Test func theRegionIsWhereBothLooked() async throws {
        var clipped = Fake(source: .pixels, found: [])
        clipped.region = ScreenRect(x: 0, y: 0, width: 500, height: 800)
        let r = try await read(Fake(source: .tree, found: []), clipped)
        #expect(r.scope.region == ScreenRect(x: 0, y: 0, width: 500, height: 800))
    }

    @Test func aWordOnlyTheSecondReaderSawIsNotCarriedAwayAsASlip() async throws {
        let r = try await read(
            Fake(source: .tree, found: [at("Downloads", 0, 0, Self.role, width: 95)]),
            Fake(source: .pixels, found: [run("Downloads 3", 0, 0)])
        )
        #expect(all(r).map(\.text.value) == ["Downloads", "3"])
        #expect(r.scope.excluded == [Exclusion(reason: .duplicate, count: 1)])
    }

    struct NoGrant: ReaderError { var missingGrant: Bool { true } }

    struct Refusing: Reader {
        let source = SourceKind.tree
        func look(_ query: Query) async throws -> Candidates { throw NoGrant() }
        func pressing(_ reading: Reading) async throws -> Reading { reading }
    }

    @Test func aBlindReadersMissingGrantIsCarriedInItsPart() async throws {
        let r = try await MergedReader(Refusing(), Fake(source: .pixels, found: []), locate: Self.here).read(Query(match: nil, region: .rect(Self.region)))
        guard case .stopped(.merged(.blind(.tree, _, let grant), _)) = r.scope.reach else { Issue.record("\(r)"); return }
        #expect(grant)
    }

    /// A reader whose place went away after the merge resolved it: a window closed between
    /// the two looks.
    struct Gone: Reader {
        let source = SourceKind.pixels
        func look(_ query: Query) async throws -> Candidates { throw NoSuchPlace.window(7) }
        func pressing(_ reading: Reading) async throws -> Reading { reading }
    }

    @Test func aPlaceGoneBeforeOneReaderLookedIsThatReadersBlindness() async throws {
        let r = try await read(Fake(source: .tree, found: [at("Allow", 10, 10, Self.role)]), Gone())
        #expect(all(r).map(\.text.value) == ["Allow"])
        guard case .stopped(.merged(.read(.tree, .whole), .blind(.pixels, _, false))) = r.scope.reach else { Issue.record("\(r)"); return }
    }

    struct Unasked: Reader {
        let source: SourceKind
        func look(_ query: Query) async throws -> Candidates {
            Issue.record("the \(source) reader was asked about a region that names nowhere")
            return Candidates(found: [], region: MergedReaderTests.region, examined: 0, excluded: [], reach: .whole)
        }
        func pressing(_ reading: Reading) async throws -> Reading { reading }
    }

    /// Refused as the merge's answer even with both readers blind, so a bad id is never
    /// hidden behind a missing grant.
    @Test func aRegionThatNamesNowhereIsRefusedOnceBeforeEitherReader() async {
        let nowhere = NoSuchPlace.display(4_000_000_000)
        for (a, b) in [(Unasked(source: .tree), Unasked(source: .pixels)) as (any Reader, any Reader), (Refusing(), Refusing())] {
            await #expect {
                _ = try await MergedReader(a, b, locate: { _ in throw nowhere }).read(Query(match: nil, region: .display(4_000_000_000)))
            } throws: { "\($0)" == nowhere.description }
        }
    }

    /// Each reader checks the rows it placed: the tree's cut stands, and the pixels reader,
    /// asked after it, sees the cut row and leaves it.
    @Test func eachReaderChecksTheBoxesOfTheRowsItPlaced() async throws {
        let cut = ScreenRect(x: 17, y: 15, width: 40, height: 12)
        let tree = Fake(source: .tree, found: [at("Allow", 10, 10, Self.role), at("Deny", 100, 10, Self.role)],
                        press: { $0.text.value == "Allow" ? .narrowed(cut) : .unchecked })
        let pixels = Fake(source: .pixels, found: [at("Allow", 12, 11, Self.seen)],
                          press: { $0.source.role == nil ? .unchecked : .kept })
        let r = try await read(tree, pixels)
        #expect(all(r).map(\.frame) == [cut, ScreenRect(x: 100, y: 10, width: 60, height: 20)])
        #expect(r.scope.boxes == Boxes(narrowed: 1, unchecked: 1))
    }
}

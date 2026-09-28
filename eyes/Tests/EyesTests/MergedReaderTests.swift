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

        struct Blind: Error, CustomStringConvertible { var description: String { "no grant" } }

        func read(_ query: Query) async throws -> Reading {
            if fails { throw Blind() }
            return Reading.judging(
                found, query: query, region: MergedReaderTests.region,
                examined: found.count, excluded: [], reach: reach
            )
        }
    }

    static let role = Source.tree(role: Role(rawValue: "AXButton"))
    static let seen = Source.pixels(confidence: Confidence(0.8)!)

    private func at(_ text: String, _ x: Double, _ y: Double, _ source: Source, width: Double = 60) -> Found {
        Found(text: Text(text)!, frame: ScreenRect(x: x, y: y, width: width, height: 20), source: source)
    }

    private func read(_ a: Fake, _ b: Fake, _ match: Match? = nil) async throws -> Reading {
        try await MergedReader(a, b).read(Query(match: match, region: .rect(Self.region)))
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
        #expect(r.scope.reach == .stopped(.merged(.blind(.tree, "no grant"), .read(.pixels, .whole))))
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
        #expect(r.scope.reach == .stopped(.merged(.read(.tree, .whole), .blind(.pixels, "no grant"))))
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
            Fake(source: .pixels, found: [at("b", 10, 200, Self.seen)])
        ).read(Query(match: nil, region: .rect(Self.region), limit: Limit(1)!))
        #expect(all(r).map(\.text.value) == ["a"])
        #expect(r.scope.reach == .stopped(.resultLimit(Limit(1)!)))
        #expect(r.scope.excluded == [Exclusion(reason: .ranked, count: 1)])
    }
}

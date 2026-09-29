import Testing
@testable import Eyes

/// The wait, over a fake read whose answer changes on its third read. The dangerous case
/// is a false "gone", so most of what is here is absence: when it may be believed, and
/// when a read that could not see must end the wait instead. [LAW:no-silent-failure]
@Suite struct WaitTests {
    static let region = ScreenRect(x: 0, y: 0, width: 800, height: 600)

    static let present = Reading(
        outcome: .matched(Matches([Found(text: Text("Save")!, frame: ScreenRect(x: 10, y: 10, width: 40, height: 20),
                                         source: .pixels(confidence: Confidence(1)!))])!),
        scope: Scope(region: region, examined: 1, reach: .whole))
    static let absent = Reading(outcome: .nearest([]), scope: Scope(region: region, examined: 0, reach: .whole))
    /// Nothing matched, but the read stopped short: not an absence.
    static let partial = Reading(outcome: .nearest([]), scope: Scope(region: region, examined: 3, reach: .stopped(.unread)))

    static let query = Query(match: .contains("Save"), region: .window(286))

    struct Blind: Error {}

    /// Hands out `script` one read at a time, its last entry forever after; an entry of
    /// nil is a read that could not look.
    final class Script: @unchecked Sendable {
        private var left: [Reading?]
        private(set) var reads = 0
        private(set) var asked: [Query] = []
        init(_ script: [Reading?]) { left = script }
        func read(_ query: Query) throws -> Reading {
            reads += 1
            asked.append(query)
            let next = left.count > 1 ? left.removeFirst() : left[0]
            guard let next else { throw Blind() }
            return next
        }
    }

    private func wait(_ until: Until, _ seconds: Double = 5, _ script: Script) async throws -> Waited {
        try await waiting(for: Wait(until: until, seconds: seconds)!, on: Self.query, every: .milliseconds(1)) { try script.read($0) }
    }

    @Test func presentSettlesOnTheReadThatMatches() async throws {
        let script = Script([Self.absent, Self.absent, Self.present])
        let waited = try await wait(.present, 5, script)
        #expect(waited.settled)
        #expect(waited.reads == 3)
        #expect(waited.reading == Self.present)
    }

    /// Gone from the third read on, and believed on the fourth: an absence is read twice
    /// running before the wait trusts it.
    @Test func absentSettlesOnTheSecondWholeReadRunning() async throws {
        let script = Script([Self.present, Self.present, Self.absent])
        let waited = try await wait(.absent, 5, script)
        #expect(waited.settled)
        #expect(waited.reads == 4)
        #expect(waited.reading == Self.absent)
    }

    /// One lost frame between two matches is the likeliest false "gone"; it starts the
    /// count over rather than ending the wait.
    @Test func oneAbsentReadAmongMatchesIsNotBelieved() async throws {
        let script = Script([Self.present, Self.absent, Self.present, Self.absent, Self.absent])
        let waited = try await wait(.absent, 5, script)
        #expect(waited.reads == 5)
        #expect(waited.settled)
    }

    /// A read that stopped short matched nothing but did not see the whole region.
    @Test func aPartialReadIsNeverAnAbsence() async throws {
        let waited = try await wait(.absent, 0.2, Script([Self.present, Self.present, Self.partial]))
        #expect(!waited.settled)
        #expect(waited.reading == Self.partial)
    }

    /// The first read finds the window; every read after it looks at the rectangle that
    /// read resolved, so a window that closes is a region with the text gone.
    @Test func readsAfterTheFirstLookAtTheRectangleItResolved() async throws {
        let script = Script([Self.present, Self.absent])
        _ = try await wait(.absent, 5, script)
        #expect(script.asked.first == Self.query)
        #expect(script.asked.dropFirst().allSatisfy { $0 == Query(match: .contains("Save"), region: .rect(Self.region)) })
    }

    /// A timeout is an answer: the last reading, marked as not settled, not an error.
    @Test func aTimeoutAnswersWithTheLastReading() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let waited = try await wait(.absent, 0.2, Script([Self.present]))
        #expect(!waited.settled)
        #expect(waited.reading == Self.present)
        #expect(waited.reads > 1)
        #expect(clock.now - started < .seconds(1))
    }

    /// A reader that could not look mid-wait ends the wait with its error, never as "gone".
    @Test func aBlindReadMidWaitThrows() async throws {
        let script = Script([Self.present, Self.present, nil])
        await #expect(throws: Blind.self) { try await wait(.absent, 5, script) }
        #expect(script.reads == 3)
    }

    @Test func aTimeoutMustBeSecondsWithinTheLongest() {
        #expect(Wait(until: .absent, seconds: 0) == nil)
        #expect(Wait(until: .absent, seconds: -1) == nil)
        #expect(Wait(until: .absent, seconds: .infinity) == nil)
        #expect(Wait(until: .absent, seconds: .nan) == nil)
        #expect(Wait(until: .absent, seconds: Wait.longest + 1) == nil)
        #expect(Wait(until: .present, seconds: 0.25)?.timeout == .milliseconds(250))
    }
}

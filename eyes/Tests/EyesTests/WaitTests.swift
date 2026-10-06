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
        func read(_ query: Query) throws -> Judged {
            reads += 1
            asked.append(query)
            let next = left.count > 1 ? left.removeFirst() : left[0]
            guard let next else { throw Blind() }
            return .standing(next)
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

    /// Every poll's boxes are left unchecked; only the reading the wait ends on is pressed,
    /// and that pressed reading is the one it answers with.
    @Test func onlyTheReadingTheWaitEndsOnIsPressed() async throws {
        final class Pressed: @unchecked Sendable { var readings: [Reading] = [] }
        let pressed = Pressed()
        let marked = Reading(outcome: Self.present.outcome, scope: Scope(region: Self.region, examined: 1, reach: .whole, boxes: Boxes(narrowed: 1)))
        let script = Script([Self.present, Self.present, Self.absent])
        let waited = try await waiting(for: Wait(until: .absent, seconds: 5)!, on: Self.query, every: .milliseconds(1)) { query in
            Judged(try script.read(query).reading) { reading, _ in pressed.readings.append(reading); return marked }
        }
        #expect(waited.reads == 4)
        #expect(pressed.readings == [Self.absent])
        #expect(waited.reading == marked)
    }

    /// The boxes are checked in what is left of the timeout, so a wait that ran out of time
    /// does not run past it checking them.
    @Test func theBoxesAreCheckedWithinTheTimeout() async throws {
        final class Given: @unchecked Sendable { var deadline: ContinuousClock.Instant? }
        let given = Given()
        let start = ContinuousClock.now
        let script = Script([Self.present])
        _ = try await waiting(for: Wait(until: .absent, seconds: 0.05)!, on: Self.query, every: .milliseconds(1)) { query in
            Judged(try script.read(query).reading) { reading, deadline in given.deadline = deadline; return reading }
        }
        #expect(given.deadline.map { $0 <= start + .milliseconds(60) } == true)
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

    /// A read that stopped short matched nothing but did not see the whole region, so it
    /// breaks a run of absences: counted as one, the wait would settle on the second read.
    /// Reads that keep stopping short never settle it, however many fit before it runs out.
    @Test func aPartialReadIsNeverAnAbsence() async throws {
        let broken = try await wait(.absent, 5, Script([Self.absent, Self.partial, Self.absent]))
        #expect(broken.settled)
        #expect(broken.reads == 4)
        let short = try await wait(.absent, 0.1, Script([Self.partial]))
        #expect(!short.settled)
        #expect(short.reading == Self.partial)
    }

    /// The first read finds the window; every read after it looks at the rectangle that
    /// read resolved, so a window that closes is a region with the text gone.
    @Test func readsAfterTheFirstLookAtTheRectangleItResolved() async throws {
        let script = Script([Self.present, Self.absent])
        _ = try await wait(.absent, 5, script)
        #expect(script.asked.first == Self.query)
        #expect(script.asked.dropFirst().allSatisfy { $0 == Query(match: .contains("Save"), region: .rect(Self.region)) })
    }

    /// A page is held to its rectangle as a window is, so a closed tab is the text gone;
    /// and every read asks the whole question, `near` and the limit too, so the one beside
    /// Beta is still the one answered once the region is pinned.
    @Test func aPinnedPageKeepsTheWholeQuestion() async throws {
        let query = Query(match: .contains("Remove"), region: .page(window: 219, frame: Self.region), limit: Limit(1)!,
                          near: .contains("Beta"))
        let script = Script([Self.present, Self.absent])
        _ = try await waiting(for: Wait(until: .absent, seconds: 5)!, on: query, every: .milliseconds(1)) { try script.read($0) }
        #expect(script.asked.first == query)
        #expect(script.asked.dropFirst().allSatisfy {
            $0 == Query(match: .contains("Remove"), region: .rect(Self.region), limit: Limit(1)!, near: .contains("Beta"))
        })
    }

    /// Matches with their anchor missing are neither found nor gone, so a wait for either
    /// runs out rather than settling on the wrong row or on a false absence.
    @Test func anUnanchoredReadingSettlesNeitherWay() async throws {
        let unanchored = Reading(outcome: .unanchored([]), scope: Scope(region: Self.region, examined: 6, reach: .whole))
        for until in [Until.present, .absent] {
            #expect(try await !wait(until, 0.1, Script([unanchored])).settled)
        }
    }

    /// A display keeps its id on every read: its old rectangle may be another monitor.
    @Test func aDisplayIsReadByItsIdEveryTime() async throws {
        let query = Query(match: .contains("Save"), region: .display(3))
        let script = Script([Self.present, Self.absent])
        _ = try await waiting(for: Wait(until: .absent, seconds: 5)!, on: query, every: .milliseconds(1)) { try script.read($0) }
        #expect(script.asked.allSatisfy { $0 == query })
    }

    /// A merge whose tree could not look never reads the region whole; waiting for an
    /// absence ends with that reader's error instead of running out the clock.
    @Test func aMergeWithABlindReaderEndsAnAbsenceWait() async throws {
        let halfBlind = Reading(outcome: .nearest([]), scope: Scope(region: Self.region, examined: 0,
            reach: .stopped(.merged(.blind(.tree, "no grant", missingGrant: true), .read(.pixels, .whole)))))
        let script = Script([Self.present, halfBlind])
        await #expect(throws: WaitBlind.self) { try await wait(.absent, 5, script) }
        #expect(script.reads == 2)
    }

    /// A timeout is an answer: the last reading, marked as not settled, not an error.
    @Test func aTimeoutAnswersWithTheLastReading() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let waited = try await wait(.absent, 0.2, Script([Self.present]))
        #expect(!waited.settled)
        #expect(waited.reading == Self.present)
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

extension Judged {
    /// A reading whose boxes stand as its reader placed them, as a fake reader's do.
    static func standing(_ reading: Reading) -> Judged { Judged(reading) { r, _ in r } }
}

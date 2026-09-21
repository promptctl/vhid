import Pointing
import Synchronization
import Testing
@testable import Input

/// A script parsed whole or refused whole, with the line that refused it named.
@Suite struct PlayTests {
    @Test func aScriptIsAStartAndItsReportsInOrder() throws {
        let play = try Play.parse("""
            {"to":{"x":800,"y":500.5}}
            {"t_ms":0,"down":"left"}

            {"t_ms":8.333,"move":{"dx":4,"dy":-127}}
            {"t_ms":8.333,"wheel":{"v":-1,"h":2}}
            {"t_ms":1000,"up":true}
            """)
        #expect(play.start == ScreenPoint(x: 800, y: 500.5)!)
        #expect(play.events == [
            Play.Timed(at: .zero, report: .down(.left)),
            Play.Timed(at: .nanoseconds(8_333_000), report: .move(Move(x: Count(clamping: 4), y: Count(clamping: -127)))),
            Play.Timed(at: .nanoseconds(8_333_000), report: .wheel(Scroll(vertical: Count(clamping: -1), horizontal: Count(clamping: 2)))),
            Play.Timed(at: .seconds(1), report: .up),
        ])
    }

    /// A script written with Windows line endings is the same script.
    @Test func crlfLinesAreLines() throws {
        let play = try Play.parse(#"{"to":{"x":1,"y":1}}"# + "\r\n" + #"{"t_ms":0,"up":true}"# + "\r\n")
        #expect(play.events == [Play.Timed(at: .zero, report: .up)])
    }

    static let start = #"{"to":{"x":1,"y":1}}"#

    /// Each refusal names the line, and says enough to fix it.
    @Test(arguments: [
        ("", 1, "at least one report"),
        (start, 1, "at least one report"),
        (#"{"t_ms":0,"up":true}"# + "\n" + #"{"t_ms":0,"up":true}"#, 1, "\"t_ms\""),
        (start + "\n" + #"{"t_ms":0,"up":true,"wheels":{}}"#, 2, "unknown key \"wheels\""),
        (start + "\n" + #"{"t_ms":0,"up":true,"down":"left"}"#, 2, "exactly one"),
        (start + "\n" + #"{"t_ms":0}"#, 2, "has none"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":128,"dy":0}}"#, 2, "move.dx is 128"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1}}"#, 2, "\"dy\" is missing"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1,"dy":0,"x":3}}"#, 2, "unknown key \"x\""),
        (start + "\n" + #"{"t_ms":-1,"up":true}"#, 2, "0 through 3600000"),
        // Numbers a script gets wrong, each named rather than handed to JSONDecoder's
        // vocabulary: every one of these used to come back "The given data was not valid
        // JSON", which is true of none of them.
        (start + "\n" + #"{"t_ms":0,"down":300}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"down":256}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"down":-3}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"down":1.5}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"down":0}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1.5,"dy":0}}"#, 2, "whole counts"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1e300,"dy":0}}"#, 2, "whole counts"),
        // And the start line's own keys, which the promise used to stop short of.
        (#"{"to":{"x":1,"y":2,"dx":99}}"# + "\n" + #"{"t_ms":0,"up":true}"#, 1, "unknown key \"dx\""),
        (#"{"to":{"x":1}}"# + "\n" + #"{"t_ms":0,"up":true}"#, 1, "y"),
        (start + "\n" + #"{"t_ms":1e13,"up":true}"#, 2, "0 through 3600000"),
        (start + "\n" + #"{"t_ms":0,"up":false}"#, 2, "\"up\":true"),
        (start + "\n" + #"{"t_ms":0,"down":"thumb"}"#, 2, "down"),
        (start + "\n" + #"{"t_ms":5,"up":true}"# + "\n" + #"{"t_ms":4,"up":true}"#, 3, "goes backwards"),
        (start + "\n" + #"{"t_ms":0,"down":"right"}"# + "\n" + #"{"t_ms":1,"move":{"dx":1,"dy":1}}"#, 3, "ends with button 2 held"),
    ])
    func aScriptThatCannotBePlayedWholeIsRefusedAtItsLine(script: String, line: Int, saying: String) throws {
        let refused = try #require(throws: Play.ScriptInvalid.self) { try Play.parse(script) }
        #expect(refused.line == line)
        #expect(refused.reason.contains(saying), "\(refused)")
    }
}

/// The player against a clock the test moves and a mouse that costs time per report.
@Suite @MainActor struct PlayerTests {
    static let epoch: Int64 = 1_700_000_000_000_000

    /// Reports are due at their offsets from one start, not from each other: a report the
    /// mouse took 3 ms to acknowledge makes the next one late, and the one after it, due
    /// later than that, still goes out on time.
    @Test func eachReportGoesOutAtItsOwnDeadlineAndALateOneIsSentLate() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 10, y: 10)!)
        let mouse = CostlyMouse(mouse: fake, clock: clock, cost: .milliseconds(3))
        let play = try Play.parse("""
            {"to":{"x":10,"y":10}}
            {"t_ms":0,"down":"left"}
            {"t_ms":1,"move":{"dx":5,"dy":0}}
            {"t_ms":10,"up":true}
            """)
        let played = try await Player(pointer: Pointer(mouse: mouse, cursor: fake.cursor), clock: clock, wall: { Self.epoch }, lead: .zero).play(play)
        #expect(played.startReports == 0)
        #expect(played.reports == [
            Played.Report(scheduled: Self.epoch, sent: Self.epoch, acked: Self.epoch + 3000),
            Played.Report(scheduled: Self.epoch + 1000, sent: Self.epoch + 3000, acked: Self.epoch + 6000),
            Played.Report(scheduled: Self.epoch + 10000, sent: Self.epoch + 10000, acked: Self.epoch + 13000),
        ])
        #expect(played.lateness.ranks == [0, 2000, 2000, 2000])
        #expect(fake.log == ["down 1", "move 5 0", "up"])
        // Only the last report was still ahead of the clock: the first was due at the
        // start and the second overdue, and neither paid for a sleep.
        #expect(clock.sleeps == 1)
    }

    /// A long wait asks whether the run was cancelled every slice, so a cancel during a
    /// minute's hold ends it one slice in and releases the button, not a minute later.
    ///
    /// Aimed at the clock rather than at a report, because the hold is where the cancel has
    /// to land: a cancel raised at the button-down would prove nothing about the wait. The
    /// task is made on this actor and cannot begin until the test suspends, so the aim is
    /// taken before the first sleep whatever the scheduler does.
    @MainActor
    @Test func aLongWaitIsCancelledWithinASlice() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        let play = try Play.parse("""
            {"to":{"x":0,"y":0}}
            {"t_ms":0,"down":"left"}
            {"t_ms":60000,"up":true}
            """)
        let run = Task { @MainActor in
            try await Player(pointer: fake.pointer, clock: clock, wall: { Self.epoch }, lead: .zero).play(play)
        }
        clock.cancel(afterSleeps: 1) { run.cancel() }
        let stopped = try await #require(throws: PlayStopped.self) { try await run.value }
        #expect(stopped.played.count == 1)
        #expect(stopped.causes.contains { $0 is CancellationError })
        #expect(clock.now.offset == Player<ManualClock>.slice)
        #expect(fake.log == ["down 1", "up"])
    }

    /// A lead, watched out on a clock that only moves when something sleeps on it.
    ///
    /// **Every other test here passes `lead: .zero`**, which skips the watch entirely - so
    /// the value a replay actually runs with, and the whole reason `WakingClock` exists,
    /// had no coverage at all. The watch yields until the deadline, which is right under a
    /// clock that advances on its own and is forever under one that does not: without the
    /// measurement that notices the clock standing still, this spins until the time limit.
    @Test(.timeLimit(.minutes(1)))
    func aLeadIsWatchedOutOnAClockThatOnlyMovesWhenSleptOn() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        let play = try Play.parse("""
            {"to":{"x":0,"y":0}}
            {"t_ms":0,"down":"left"}
            {"t_ms":10,"up":true}
            """)
        let played = try await Player(pointer: fake.pointer, clock: clock, wall: { Self.epoch }, lead: .milliseconds(2)).play(play)
        #expect(played.reports.map(\.scheduled) == [Self.epoch, Self.epoch + 10_000])
        // The watch put the clock exactly on the deadline, so nothing went out late.
        #expect(played.lateness.max == 0)
        #expect(fake.log == ["down 1", "up"])
    }

    @Test func latenessIsReadByNearestRank() {
        #expect(Lateness(of: (1...100).map(Int64.init).shuffled()).ranks == [50, 90, 99, 100])
        #expect(Lateness(of: [7]).ranks == [7, 7, 7, 7])
    }

    /// A refused report stops the play with what went out before it, releases every
    /// button, and says when that release was refused too.
    @Test func aStopSaysHowFarThePlayGotAndReleases() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        fake.allow = 1
        let play = try Play.parse("""
            {"to":{"x":0,"y":0}}
            {"t_ms":0,"down":"left"}
            {"t_ms":1,"move":{"dx":5,"dy":0}}
            {"t_ms":2,"up":true}
            """)
        let stopped = try await #require(throws: PlayStopped.self) {
            try await Player(pointer: fake.pointer, clock: clock, wall: { Self.epoch }, lead: .zero).play(play)
        }
        #expect(stopped.played.count == 1)
        #expect(stopped.of == 3)
        #expect(stopped.causes.contains { $0 is Refused })
        #expect("\(stopped)".contains("after 1 of 3 reports"))
        #expect("\(stopped)".contains("A button may be left held"))
        #expect(fake.log == ["down 1", "move 5 0", "up"])
    }
}

extension Lateness {
    var ranks: [Int64] { [p50, p90, p99, max] }
}

/// A mouse whose every report takes `cost` on the clock, as a helper round trip does.
struct CostlyMouse: Mouse {
    let mouse: FakeMouse
    let clock: ManualClock
    let cost: Duration

    func down(_ button: Button) async throws { clock.advance(by: cost); try mouse.down(button) }
    func releaseAll() async throws { clock.advance(by: cost); try mouse.releaseAll() }
    func move(by delta: Move) async throws { clock.advance(by: cost); try mouse.move(by: delta) }
    func scroll(by delta: Scroll) async throws { clock.advance(by: cost); try mouse.scroll(by: delta) }
}

/// A clock that moves only when told to, or when something sleeps until later than now.
final class ManualClock: Clock {
    struct Instant: InstantProtocol {
        let offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private let current = Mutex(Instant(offset: .zero))
    private let slept = Mutex(0)
    /// What to do once something has slept here often enough, for a test that needs a
    /// stop to land inside a wait rather than at a report. [LAW:effects-at-boundaries]
    private let aim = Mutex<(after: Int, fire: (@Sendable () -> Void)?)>((.max, nil))

    var now: Instant { current.withLock { $0 } }
    var minimumResolution: Duration { .zero }
    /// How many times something has slept on this clock.
    var sleeps: Int { slept.withLock { $0 } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let sleeps = slept.withLock { $0 += 1; return $0 }
        current.withLock { $0 = Swift.max($0, deadline) }
        aim.withLock { if sleeps >= $0.after { $0.fire?() } }
    }

    func cancel(afterSleeps sleeps: Int, _ fire: @escaping @Sendable () -> Void) {
        aim.withLock { $0 = (sleeps, fire) }
    }

    func advance(by duration: Duration) {
        current.withLock { $0 = $0.advanced(by: duration) }
    }
}

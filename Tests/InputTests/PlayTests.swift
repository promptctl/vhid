import Keystrokes
import Pointing
import Synchronization
import Testing
@testable import Input

/// A script parsed whole or refused whole, with the line that refused it named.
@Suite struct PlayTests {
    @Test func aScriptIsAStartAndItsReportsInOrder() throws {
        let play = try Play.parse("""
            {"to":{"x":800,"y":500.5}}
            {"t_ms":0,"buttons":["left"]}

            {"t_ms":8.333,"move":{"dx":4,"dy":-127}}
            {"t_ms":8.333,"wheel":{"v":-1,"h":2}}
            {"t_ms":1000,"buttons":[]}
            """)
        #expect(play.start == ScreenPoint(x: 800, y: 500.5)!)
        #expect(play.events == [
            Play.Timed(at: .zero, report: .buttons([.left]), line: 2),
            Play.Timed(at: .nanoseconds(8_333_000), report: .move(Move(x: Count(clamping: 4), y: Count(clamping: -127))), line: 4),
            Play.Timed(at: .nanoseconds(8_333_000), report: .wheel(Scroll(vertical: Count(clamping: -1), horizontal: Count(clamping: 2))), line: 5),
            Play.Timed(at: .seconds(1), report: .buttons([]), line: 6),
        ])
    }

    /// Keys and buttons are whole held sets on the pointer's clock, and a key is named by a
    /// modifier, a chord's key name, or its usage number.
    @Test func keyboardAndPointerLinesShareOneClock() throws {
        let play = try Play.parse("""
            {"to":{"x":10,"y":20}}
            {"t_ms":0,"keys":["leftShift",4]}
            {"t_ms":5,"buttons":["left",8]}
            {"t_ms":6,"at":{"x":12.5,"y":20}}
            {"t_ms":7,"keys":["return"]}
            {"t_ms":8,"keys":[]}
            {"t_ms":9,"buttons":[]}
            """)
        #expect(play.events == [
            Play.Timed(at: .zero, report: .keys(try HeldKeys([.leftShift, Usage(rawValue: 4)])), line: 2),
            Play.Timed(at: .milliseconds(5), report: .buttons([.left, Button(rawValue: 8)!]), line: 3),
            Play.Timed(at: .milliseconds(6), report: .at(ScreenPoint(x: 12.5, y: 20)!), line: 4),
            Play.Timed(at: .milliseconds(7), report: .keys(try HeldKeys([Usage(rawValue: 0x28)])), line: 5),
            Play.Timed(at: .milliseconds(8), report: .keys(.none), line: 6),
            Play.Timed(at: .milliseconds(9), report: .buttons([]), line: 7),
        ])
    }

    /// As many keys as one report carries is a set a script may hold.
    @Test func thirtyTwoKeysAreOneReport() throws {
        let keys = (4...35).map(String.init).joined(separator: ",")
        let play = try Play.parse(Self.start + "\n" + #"{"t_ms":0,"keys":[\#(keys),"leftShift"]}"# + "\n" + #"{"t_ms":1,"keys":[]}"#)
        guard case .keys(let held) = play.events.first?.report else { Issue.record("not a keys line"); return }
        #expect(held.usages.count == 33)
    }

    /// A script written with Windows line endings is the same script.
    @Test func crlfLinesAreLines() throws {
        let play = try Play.parse(#"{"to":{"x":1,"y":1}}"# + "\r\n" + #"{"t_ms":0,"buttons":[]}"# + "\r\n")
        #expect(play.events == [Play.Timed(at: .zero, report: .buttons([]), line: 2)])
    }

    static let start = #"{"to":{"x":1,"y":1}}"#

    /// Each refusal names the line, and says enough to fix it.
    @Test(arguments: [
        ("", 1, "at least one report"),
        (start, 1, "at least one report"),
        (#"{"t_ms":0,"buttons":[]}"# + "\n" + #"{"t_ms":0,"buttons":[]}"#, 1, "\"t_ms\""),
        (start + "\n" + #"{"t_ms":0,"buttons":[],"wheels":{}}"#, 2, "unknown key \"wheels\""),
        (start + "\n" + #"{"t_ms":0,"buttons":[],"keys":[]}"#, 2, "exactly one"),
        (start + "\n" + #"{"t_ms":0}"#, 2, "has none"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":128,"dy":0}}"#, 2, "move.dx is 128"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1}}"#, 2, "\"dy\" is missing"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1,"dy":0,"x":3}}"#, 2, "unknown key \"x\""),
        (start + "\n" + #"{"t_ms":-1,"buttons":[]}"#, 2, "0 through 3600000"),
        // Numbers a script gets wrong, each named rather than handed to JSONDecoder's
        // vocabulary: every one of these used to come back "The given data was not valid
        // JSON", which is true of none of them.
        (start + "\n" + #"{"t_ms":0,"buttons":[300]}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"buttons":[256]}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"buttons":[-3]}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"buttons":[1.5]}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"buttons":[0]}"#, 2, "whole number from 1 to 32"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1.5,"dy":0}}"#, 2, "whole counts"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1e300,"dy":0}}"#, 2, "whole counts"),
        // And the start line's own keys, which the promise used to stop short of.
        (#"{"to":{"x":1,"y":2,"dx":99}}"# + "\n" + #"{"t_ms":0,"buttons":[]}"#, 1, "unknown key \"dx\""),
        (#"{"to":{"x":1}}"# + "\n" + #"{"t_ms":0,"buttons":[]}"#, 1, "y"),
        (start + "\n" + #"{"t_ms":1e13,"buttons":[]}"#, 2, "0 through 3600000"),
        (start + "\n" + #"{"t_ms":0,"buttons":["thumb"]}"#, 2, "names no button"),
        (start + "\n" + #"{"t_ms":5,"buttons":[]}"# + "\n" + #"{"t_ms":4,"buttons":[]}"#, 3, "goes backwards"),
        (start + "\n" + #"{"t_ms":0,"buttons":["right"]}"# + "\n" + #"{"t_ms":1,"move":{"dx":1,"dy":1}}"#, 3, "ends with button 2 held"),
        (start + "\n" + #"{"t_ms":0,"keys":["leftShift"]}"#, 2, "ends with leftShift held"),
        (start + "\n" + #"{"t_ms":0,"keys":["leftShift"]}"# + "\n" + #"{"t_ms":1,"buttons":[]}"#, 3, "ends with leftShift held"),
        (start + "\n" + #"{"t_ms":0,"move":{"dx":1,"dy":0}}"# + "\n" + #"{"t_ms":1,"at":{"x":5,"y":5}}"#, 3, "move lines or with at lines"),
        (start + "\n" + #"{"t_ms":0,"keys":[3]}"#, 2, "usage number from 4 to 231"),
        (start + "\n" + #"{"t_ms":0,"keys":[232]}"#, 2, "usage number from 4 to 231"),
        (start + "\n" + #"{"t_ms":0,"keys":[4.5]}"#, 2, "usage number from 4 to 231"),
        (start + "\n" + #"{"t_ms":0,"keys":["a"]}"#, 2, "names no key"),
        (start + "\n" + #"{"t_ms":0,"keys":["function"]}"#, 2, "names no key"),
        (start + "\n" + #"{"t_ms":0,"keys":[4,4]}"#, 2, "names one entry twice"),
        (start + "\n" + #"{"t_ms":0,"buttons":["left",1]}"#, 2, "names one entry twice"),
        (start + "\n" + #"{"t_ms":0,"keys":[\#((4...36).map(String.init).joined(separator: ","))]}"#, 2, "holds 33 keys"),
        (start + "\n" + #"{"t_ms":0,"at":{"x":1}}"#, 2, "y"),
        (start + "\n" + #"{"t_ms":0,"at":{"x":1,"y":2,"z":3}}"#, 2, "unknown key \"z\""),
        (start + "\n" + #"{"t_ms":0,"keys":"leftShift"}"#, 2, "keys"),
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
            {"t_ms":0,"buttons":["left"]}
            {"t_ms":1,"move":{"dx":5,"dy":0}}
            {"t_ms":10,"buttons":[]}
            """)
        let played = try await Player(pointer: Pointer(mouse: mouse, cursor: fake.cursor), keyboard: fake.keyboard, clock: clock, wall: { Self.epoch }, lead: .zero).play(Schedule(play))
        #expect(played.startReports == 0)
        #expect(played.reports == [
            Played.Report(line: 2, scheduled: Self.epoch, sent: Self.epoch, acked: Self.epoch + 3000),
            Played.Report(line: 3, scheduled: Self.epoch + 1000, sent: Self.epoch + 3000, acked: Self.epoch + 6000),
            Played.Report(line: 4, scheduled: Self.epoch + 10000, sent: Self.epoch + 10000, acked: Self.epoch + 13000),
        ])
        #expect(played.lateness.ranks == [0, 2000, 2000, 2000])
        #expect(fake.log == ["hold [1]", "move 5 0", "hold []"])
        // Only the last report was still ahead of the clock: the first was due at the
        // start and the second overdue, and neither paid for a sleep.
        #expect(clock.sleeps == 1)
    }

    /// A long wait asks whether the run was cancelled every slice, so a cancel during a
    /// minute's hold ends it one slice in and releases the button, not a minute later. The
    /// script holds no key, so the keyboard is not touched on the way out.
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
            {"t_ms":0,"buttons":["left"]}
            {"t_ms":60000,"buttons":[]}
            """)
        let run = Task { @MainActor in
            try await Player(pointer: fake.pointer, keyboard: fake.keyboard, clock: clock, wall: { Self.epoch }, lead: .zero).play(Schedule(play))
        }
        clock.cancel(afterSleeps: 1) { run.cancel() }
        let stopped = try await #require(throws: PlayStopped.self) { try await run.value }
        #expect(stopped.played.count == 1)
        #expect(stopped.causes.contains { $0 is CancellationError })
        #expect(clock.now.offset == Player<ManualClock>.slice)
        #expect(fake.log == ["hold [1]", "up"])
    }

    /// A lead, watched out on a clock that only moves when something sleeps on it.
    ///
    /// **Every other test here passes `lead: .zero`**, which skips the watch entirely - so
    /// the value a replay actually runs with had no coverage at all. The watch yields until
    /// the deadline, which is right under a clock that advances on its own and is forever
    /// under one that does not: without the
    /// measurement that notices the clock standing still, this spins until the time limit.
    @Test(.timeLimit(.minutes(1)))
    func aLeadIsWatchedOutOnAClockThatOnlyMovesWhenSleptOn() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        let play = try Play.parse("""
            {"to":{"x":0,"y":0}}
            {"t_ms":0,"buttons":["left"]}
            {"t_ms":10,"buttons":[]}
            """)
        let played = try await Player(pointer: fake.pointer, keyboard: fake.keyboard, clock: clock, wall: { Self.epoch }, lead: .milliseconds(2)).play(Schedule(play))
        #expect(played.reports.map(\.scheduled) == [Self.epoch, Self.epoch + 10_000])
        // The watch put the clock exactly on the deadline, so nothing went out late.
        #expect(played.lateness.max == 0)
        #expect(fake.log == ["hold [1]", "hold []"])
    }

    /// A script over both devices goes out in its order on one clock: a key held through a
    /// drag is said again each quiet second without a report of its own, and every set is
    /// posted whole.
    @Test func aMixedScriptGoesOutInOrderOnOneClock() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        let play = try Play.parse("""
            {"to":{"x":0,"y":0}}
            {"t_ms":0,"keys":["leftShift"]}
            {"t_ms":10,"buttons":["left"]}
            {"t_ms":20,"move":{"dx":5,"dy":0}}
            {"t_ms":1500,"wheel":{"v":-1,"h":0}}
            {"t_ms":1600,"buttons":["left","right"]}
            {"t_ms":1700,"buttons":["right"]}
            {"t_ms":1800,"keys":["leftShift",4]}
            {"t_ms":1900,"keys":[]}
            {"t_ms":2000,"buttons":[]}
            """)
        let played = try await Player(pointer: fake.pointer, keyboard: fake.keyboard, clock: clock, wall: { Self.epoch }, lead: .zero).play(Schedule(play))
        #expect(fake.log == [
            "keys hold [e1]", "hold [1]", "move 5 0", "keys hold [e1]", "scroll -1 0",
            "hold [1 2]", "hold [2]", "keys hold [4 e1]", "keys hold []", "hold []",
        ])
        #expect(played.reports.map(\.line) == [2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(played.reports.map(\.scheduled) == [0, 10, 20, 1500, 1600, 1700, 1800, 1900, 2000].map { Self.epoch + $0 * 1000 })
    }

    @Test func latenessIsReadByNearestRank() {
        #expect(Lateness(of: (1...100).map(Int64.init).shuffled()).ranks == [50, 90, 99, 100])
        #expect(Lateness(of: [7]).ranks == [7, 7, 7, 7])
    }

    /// A refused report stops the play with what went out before it, releases every key
    /// and button, and says when a release was refused too.
    @Test func aStopSaysHowFarThePlayGotAndReleases() async throws {
        let clock = ManualClock()
        let fake = FakeMouse(at: ScreenPoint(x: 0, y: 0)!)
        fake.refused = 1 ..< .max
        let play = try Play.parse("""
            {"to":{"x":0,"y":0}}
            {"t_ms":0,"keys":["leftShift"]}
            {"t_ms":0,"buttons":["left"]}
            {"t_ms":1,"move":{"dx":5,"dy":0}}
            {"t_ms":2,"buttons":[]}
            {"t_ms":2,"keys":[]}
            """)
        let stopped = try await #require(throws: PlayStopped.self) {
            try await Player(pointer: fake.pointer, keyboard: fake.keyboard, clock: clock, wall: { Self.epoch }, lead: .zero).play(Schedule(play))
        }
        #expect(stopped.played.count == 1)
        #expect(stopped.of == 5)
        #expect(stopped.causes.contains { $0 is Refused })
        #expect("\(stopped)".contains("after 1 of 5 reports"))
        #expect("\(stopped)".contains("A key may be left held"))
        #expect("\(stopped)".contains("A button may be left held"))
        #expect(fake.log == ["keys hold [e1]", "hold [1]", "keys up", "up"])
    }
}

extension Lateness {
    var ranks: [Int64] { [p50, p90, p99, max] }
}

/// A mouse whose every report takes `cost` on the clock, as a vhidd round trip does.
struct CostlyMouse: Mouse {
    let mouse: FakeMouse
    let clock: ManualClock
    let cost: Duration

    func down(_ button: Button) async throws { clock.advance(by: cost); try mouse.down(button) }
    func releaseAll() async throws { clock.advance(by: cost); try mouse.releaseAll() }
    func hold(_ buttons: Set<Button>) async throws { clock.advance(by: cost); try mouse.hold(buttons) }
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

/// What `vhid play` sends of a script, decided before anything is connected.
@Suite struct ScheduleTests {
    static let start = #"{"to":{"x":1,"y":1}}"#

    private func schedule(_ lines: String) throws -> Schedule {
        try Schedule(Play.parse(Self.start + "\n" + lines))
    }

    /// Every held set is one act, whatever it adds or lets go of; a line that restates
    /// what is held sends nothing.
    @Test func heldSetsAreOneActEach() throws {
        let script = try schedule("""
            {"t_ms":0,"buttons":["left","right"]}
            {"t_ms":1,"buttons":["left","right"]}
            {"t_ms":2,"buttons":["left"]}
            {"t_ms":3,"keys":["leftShift",4]}
            {"t_ms":4,"keys":["leftShift"]}
            {"t_ms":5,"keys":["leftShift"]}
            {"t_ms":6,"keys":[]}
            {"t_ms":7,"buttons":[]}
            """)
        #expect(script.acts == [
            Schedule.Act(at: .zero, report: .buttons([.left, .right]), line: 2),
            Schedule.Act(at: .milliseconds(2), report: .buttons([.left]), line: 4),
            Schedule.Act(at: .milliseconds(3), report: .keys(try HeldKeys([.leftShift, Usage(rawValue: 4)])), line: 5),
            Schedule.Act(at: .milliseconds(4), report: .keys(try HeldKeys([.leftShift])), line: 6),
            Schedule.Act(at: .milliseconds(6), report: .keys(.none), line: 8),
            Schedule.Act(at: .milliseconds(7), report: .buttons([]), line: 9),
        ])
        #expect(script.reports == 6)
    }

    /// A key held through a quiet stretch is said again every second of it, carrying the
    /// line that pressed it, so vhidd's two-second limit never cuts it; a held button, which
    /// vhidd does not time, is not.
    @Test func aKeyHeldThroughAQuietStretchIsKeptAlive() throws {
        let script = try schedule("""
            {"t_ms":0,"keys":["leftShift"]}
            {"t_ms":0,"buttons":["left"]}
            {"t_ms":2500,"buttons":[]}
            {"t_ms":3000,"keys":[]}
            {"t_ms":3000,"buttons":["right"]}
            {"t_ms":9000,"buttons":[]}
            """)
        let shift = try HeldKeys([.leftShift])
        #expect(script.acts == [
            Schedule.Act(at: .zero, report: .keys(shift), line: 2),
            Schedule.Act(at: .zero, report: .buttons([.left]), line: 3),
            Schedule.Act(at: .seconds(1), report: .keepAlive(shift), line: 2),
            Schedule.Act(at: .seconds(2), report: .keepAlive(shift), line: 2),
            Schedule.Act(at: .milliseconds(2500), report: .buttons([]), line: 4),
            Schedule.Act(at: .seconds(3), report: .keys(.none), line: 5),
            Schedule.Act(at: .seconds(3), report: .buttons([.right]), line: 6),
            Schedule.Act(at: .seconds(9), report: .buttons([]), line: 7),
        ])
        #expect(script.reports == 6)
    }

    /// What the player does not send is refused at the line that asks for it.
    @Test(arguments: [
        (#"{"t_ms":0,"at":{"x":5,"y":5}}"#, 2, "does not steer to at lines"),
        (#"{"t_ms":0,"buttons":[]}"# + "\n" + #"{"t_ms":1,"keys":[]}"#, 2, "no line of this script"),
    ])
    func whatThePlayerDoesNotSendIsRefusedAtItsLine(lines: String, line: Int, saying: String) throws {
        let play = try Play.parse(Self.start + "\n" + lines)
        let refused = try #require(throws: Play.ScriptInvalid.self) { try Schedule(play) }
        #expect(refused.line == line)
        #expect(refused.reason.contains(saying), "\(refused)")
    }
}

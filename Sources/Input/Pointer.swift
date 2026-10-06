import Foundation
import Pointing

/// How many times a click clicks. At least one, because a click that does not click is a
/// move and there is already a move. [LAW:parse-dont-validate]
///
/// **There is no upper bound, and there used to be.** It was three - "a fourth click means
/// nothing more than a third" - which is a claim about what macOS makes of a click count,
/// not about what the device can do. The device can press a button as many times as it is
/// asked to, and a caller who wants five presses is not confused. A run that turns out to
/// be longer than its caller wanted is stopped by cancelling it.
public struct Clicks: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: Int

    public init?(rawValue: Int) {
        guard rawValue >= 1 else { return nil }
        self.rawValue = rawValue
    }

    public static let single = Clicks(rawValue: 1)!
    public static let double = Clicks(rawValue: 2)!
}

/// The pointer: absolute places on the screen turned into the deltas the device speaks,
/// clicks made where they were asked for, and every button released again when a run
/// stops.
///
/// **Absolute motion is a loop, because macOS accelerates hardware motion.** A report of
/// 127 counts does not move the cursor 127 points; it moves it by whatever the pointer
/// acceleration curve makes of that speed, which the device is not told. So the pointer
/// posts a delta toward the target, reads where the cursor actually went, and posts the
/// next delta from there - and it learns the gain as it goes: each report's observed
/// motion over its requested motion is the estimate the next request is divided by, and
/// the next request is never a faster report than the one it was learned from. The curve
/// grows with speed, so a report no faster moves no further per count, each step
/// undershoots rather than overshoots, and the loop converges from below.
/// [LAW:no-ambient-temporal-coupling] The cursor's position is the state the loop waits
/// on, never a sleep after a report.
///
/// **That loop is how a move ends, not how it travels.** A verb's move first follows a
/// person's trajectory, a report every `tick` on `timeline`, and only the last fraction of a
/// point is `home`'s. The ticks are the hand's pace, not a wait for the cursor: each is
/// aimed from where the cursor was read. `docs/design/human.md`.
///
/// Where the cursor is is read through a closure the caller hands in, so the loop runs
/// against a fake screen with a fake curve in a test and against the window server in
/// the field. [LAW:effects-at-boundaries]
///
/// **Nothing here asks whether the click should be made.** What stopped a report used to
/// be a veto the caller could fail - the app in front had changed, a system alert was up -
/// and the pointer no longer holds any such opinion. What remains is the device saying it
/// cannot: a cursor that will not go where it is sent is `WouldNotReach`, which is a fact
/// about the screen and not a judgement about the caller.
public struct Pointer: Sendable {
    public let mouse: any Mouse
    /// Where the cursor is now, in the same coordinates as the targets.
    public let cursor: @Sendable () async throws -> ScreenPoint
    /// Where the displays are, read at the start of every move, so a path is kept on the
    /// layout as it is then.
    public let displays: @Sendable () async throws -> Displays

    /// The most motion reports one move may take. Each halves the remaining distance or
    /// better once the gain is known, so a screen's width takes a handful; the cap is for
    /// a cursor that will not go where it is sent, so that is a named failure and not a
    /// loop without end.
    public static let rounds = 64
    /// How many reports in a row may leave the cursor no closer before the move is given
    /// up. One is the first step's overshoot before the gain is known; three is a cursor
    /// pinned at a screen edge or a mouse whose reports go nowhere.
    public static let stalls = 3
    /// How long one report is given to move the cursor before it is taken as having moved
    /// it nowhere. The window server applies a report within a frame or two; this is many.
    public static let settle: Duration = .milliseconds(50)

    /// What everything this pointer waits on is timed on - a move's ticks, the settle after
    /// a report, a scroll's rests, calibration's bursts and a play's deadlines - so a test
    /// runs all of it on one clock of its own. [LAW:effects-at-boundaries]
    /// [LAW:one-source-of-truth] One pointer, one clock.
    public let timeline: Timeline
    /// What every move's trajectory is drawn from.
    public let randomness: RandomSource
    /// Where every move is handed once it has ended, however it ended: the record of the
    /// verb it is part of. [LAW:nothing-unseen] A move that threw is the one most worth
    /// seeing, so the pointer hands it over, not the verb that may never get it back.
    public let traced: @Sendable (Moved) -> Void

    /// How often a moving pointer reports: every 8 ms, a 125 Hz USB mouse's rate.
    public static let tick: Duration = .milliseconds(8)

    public init<C: Clock>(mouse: any Mouse, cursor: @escaping @Sendable () async throws -> ScreenPoint, displays: @escaping @Sendable () async throws -> Displays,
                          clock: C, randomness: RandomSource, traced: @escaping @Sendable (Moved) -> Void) where C.Duration == Duration {
        self.mouse = mouse
        self.cursor = cursor
        self.displays = displays
        timeline = Timeline(clock)
        self.randomness = randomness
        self.traced = traced
    }

    /// A clock as offsets from when the pointer was made: what time it is, and a sleep
    /// until a given one. A move's deadlines are offsets from its start, so this is all of
    /// a clock a pointer needs, and it keeps the pointer free of the clock's type.
    public struct Timeline: Sendable {
        public let now: @Sendable () -> Duration
        public let sleep: @Sendable (_ until: Duration) async throws -> Void

        public init<C: Clock>(_ clock: C) where C.Duration == Duration {
            let origin = clock.now
            now = { origin.duration(to: clock.now) }
            sleep = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: .zero) }
        }
    }

    /// A click that landed: where, and the move that got it there.
    ///
    /// `at` is where the cursor was when the button went down, read back rather than
    /// repeated from the request. [FRAMING:representation] The move stops beside a target
    /// the device cannot land on exactly, so the point asked for and the point pressed are
    /// two different facts - and this is the one positional thing a caller is told, so it
    /// has to be the one that happened.
    public struct Click: Equatable, Sendable {
        public let at: ScreenPoint
        public let moved: Moved
    }

    /// A move: how long its trajectory was drawn to take, how much of its drawn bow the
    /// displays let it keep, the motion reports that steered it along that and then homed
    /// it onto the target, and how many steered reports the cursor never showed.
    /// [LAW:nothing-unseen] How well the steering landed is the closing count; how well it
    /// was tracked is `lost`; how near an edge it ran is `kept` below one.
    public struct Moved: Equatable, Sendable {
        public let planned: Duration
        public let kept: Double
        public let steered: Int
        public let closing: Int
        public let lost: Int

        public var reports: Int { steered + closing }
    }

    /// How far the OS carries the cursor per count, and for how fast a report that holds.
    ///
    /// **Two numbers, because the curve is a curve.** Measured on this Mac, with reports a
    /// tenth of a second apart: a two-count report moves the cursor 0.25 points a count and
    /// a four-count report 0.59. A gain alone, learned from a slow report, asks for a faster
    /// one, which overshoots; learned from that, it asks for a slower one, which falls short,
    /// and some moves went round that cycle until the 64 reports ran out, each a
    /// `WouldNotReach` beside its target. The gain is only known to be an upper bound for
    /// reports no faster than the one it was read from, so that speed travels with it and
    /// caps the next ask. With the cap, 300 drags between random points reached both ends,
    /// none failing, in a median of 17 reports each for the approach and the carry together.
    /// [LAW:types-are-the-program]
    public struct Gain: Equatable, Sendable {
        /// Points per count.
        public let perCount: Double
        /// The length, in counts, of the fastest report `perCount` holds for.
        public let upTo: Double

        public init(perCount: Double, upTo: Double) {
            self.perCount = perCount
            self.upTo = upTo
        }

        /// Before any report: one point a count, for a report of any speed. The first
        /// report may be thrown further than asked, which is the one stall a move allows.
        public static let assumed = Gain(perCount: 1, upTo: .infinity)
    }

    /// The next report toward `to` from `from`: the remaining distance over the gain,
    /// rounded toward zero so a known gain undershoots, shortened to no faster than the
    /// report the gain was read from, and clamped to the report's edge. Zero on an axis
    /// within half a point, which is arrived. Pure. [LAW:decomposition]
    public static func step(from: ScreenPoint, to: ScreenPoint, gain: Gain) -> Move {
        let wanted = (x: (to.x - from.x) / gain.perCount, y: (to.y - from.y) / gain.perCount)
        let scale = min(1, gain.upTo / hypot(wanted.x, wanted.y))
        return Move(x: step(to.x - from.x, wanted.x * scale), y: step(to.y - from.y, wanted.y * scale))
    }

    /// Otherwise at least one count in the target's direction, so a gain estimate too high
    /// to ask for a whole count still asks for something. Whether that floor got the cursor
    /// anywhere is not a question about these numbers - it is a question about what the
    /// report did - so it is asked in `move`, against the motion that actually happened,
    /// and not guessed at here from an estimate. [LAW:decomposition]
    private static func step(_ distance: Double, _ wanted: Double) -> Count {
        guard abs(distance) > 0.5 else { return .zero }
        let counts = min(Double(Count.limit), max(1, abs(wanted).rounded(.towardZero)))
        return Count(clamping: Int(distance < 0 ? -counts : counts))
    }

    /// Whether this report is the smallest one the device has: a single count on either
    /// axis and nothing on the other. There is nothing to ask for below it, so a report
    /// this size that left the cursor no nearer is the end of the approach rather than a
    /// round to try again. [LAW:dataflow-not-control-flow]
    private static func isSmallest(_ step: Move) -> Bool {
        abs(Int(step.x.value)) <= 1 && abs(Int(step.y.value)) <= 1
    }

    /// The gain the last report showed: points moved per count asked, holding for reports
    /// up to that one's length. A report that moved the cursor nowhere says the estimate
    /// was too high to move a whole point, so it is halved, and the next request doubles
    /// until something moves - at any speed, since nothing is known to hold for any.
    static func gain(after step: Move, from before: ScreenPoint, to after: ScreenPoint, previous: Gain) -> Gain {
        let asked = hypot(Double(step.x.value), Double(step.y.value))
        let moved = hypot(after.x - before.x, after.y - before.y)
        return moved > 0 ? Gain(perCount: moved / asked, upTo: asked) : Gain(perCount: previous.perCount / 2, upTo: .infinity)
    }

    /// Moves the cursor to `target` as a person's hand would, and lands it there as `home`
    /// does: along a `Trajectory` drawn from `randomness` and kept on `displays`, a report every `tick`, each aimed
    /// at where the trajectory is at that tick's deadline from where the cursor was read and
    /// the reports it has not yet shown. The deadlines are counted from the start, so a late
    /// report is followed by a larger one rather than pushing the rest of the path back.
    /// `docs/design/human.md`, "Steering the path".
    ///
    /// Then the closed loop, its reports `tick` apart, takes the cursor the last fraction of
    /// a point, once every report the trajectory sent has shown or been given up on - so it
    /// starts from where the cursor is, not from where it was a report ago.
    ///
    /// The move is handed to `traced` on every way out, thrown or returned, with the
    /// reports it got to.
    @discardableResult
    public func move(to target: ScreenPoint) async throws -> Moved {
        let start = try await cursor()
        let displays = try await displays()
        let trajectory = randomness.draw { Trajectory(from: start, to: target, within: displays, drawing: &$0) }
        let began = timeline.now()
        var tracking = Tracking(at: trajectory.start)
        let ticks = Int((trajectory.duration / Self.tick).rounded(.up))
        var steered = 0, closing = 0
        var moved: Moved { Moved(planned: trajectory.duration, kept: trajectory.kept, steered: steered, closing: closing, lost: tracking.lost) }
        defer { traced(moved) }
        for tick in stride(from: 1, through: ticks, by: 1) {
            try Task.checkCancellation()
            try await timeline.sleep(began + Self.tick * tick)
            tracking.saw(try await cursor(), on: tick)
            let report = tracking.report(toward: trajectory.point(after: Self.tick * tick))
            // A tick whose share of the path is under half a count sends nothing, as a
            // still mouse does; what it leaves the next tick takes up.
            guard report != .none else { continue }
            try await mouse.move(by: report)
            tracking.sent(report, on: tick)
            steered += 1
        }
        _ = try await settle { tracking.saw($0, on: ticks); return tracking.unseen.isEmpty }
        tracking.giveUp()
        var slot = began + Self.tick * ticks
        // Counted as each report is paced, which is just before it goes out, so a move the
        // closing loop threw out of still says how far it got.
        do {
            _ = try await home(on: trajectory.target) {
                closing += 1
                slot += Self.tick
                try await timeline.sleep(slot)
            }
        } catch let stop as WouldNotReach {
            // The move's reports, not the closing loop's alone: what the error says the move
            // sent is what the record counts. [LAW:one-source-of-truth]
            throw WouldNotReach(target: stop.target, cursor: stop.cursor, reports: steered + stop.reports)
        }
        return moved
    }

    /// Moves the cursor to `target` by the closed loop alone, its reports as fast as the
    /// cursor shows them, and answers with how many reports it took. `vhid play` homes this
    /// way before a click; the verbs reach it through `move`.
    @discardableResult
    public func home(on target: ScreenPoint) async throws -> Int {
        try await home(on: target) {}
    }

    /// The closed loop, waiting on `pace` before each report.
    ///
    /// Within half a point on each axis where the device can do that, and otherwise as
    /// near as one count of its motion puts it: a mouse whose smallest report moves three
    /// points cannot land on a point 1.4 points away, and this stops beside it rather than
    /// stepping over it forever. `WouldNotReach` stays what it always was - a cursor that
    /// will not go where it is sent, three reports running - and is never the last count
    /// of an approach that had arrived.
    ///
    /// Cancellation is checked once per round, which is once per report: the rounds are
    /// the only place this loop can be left without a button held, because every other
    /// line of it is a read. [LAW:dataflow-not-control-flow]
    ///
    /// **The approach ends when one count of motion stops helping**, which is the
    /// difference between a device that cannot do better and a cursor that will not go.
    /// On a Mac whose tracking speed is turned up a single count carries the cursor
    /// several points, so the last stretch is a remainder no report can land on: asking
    /// again is an oscillation, and it used to run out the round cap and report
    /// `WouldNotReach` about a target the cursor was already beside. Measured at gain 3
    /// with 1.4 points left: 64 rounds of `move -1` and `move 1`, ending where it started.
    ///
    /// The test is the report and not the estimate. `gain` is learned from the last report,
    /// which near the target was a bigger and faster one than this, and macOS moves a slow
    /// report less per count than a fast one - so an estimate is exactly the wrong thing to
    /// decide this with, and what happened is exactly the right thing.
    /// `aMoveEndsBesideTheTargetRatherThanOscillatingPastIt` holds it over four gains and
    /// six remainders. [LAW:verifiable-goals]
    func home(on target: ScreenPoint, pace: () async throws -> Void) async throws -> Int {
        var at = try await cursor()
        var gain = Gain.assumed
        var stalls = 0
        for reports in 0..<Self.rounds {
            try Task.checkCancellation()
            let step = Self.step(from: at, to: target, gain: gain)
            guard step != .none else { return reports }
            try await pace()
            try await mouse.move(by: step)
            let landed = try await settled(from: at)
            gain = Self.gain(after: step, from: at, to: landed, previous: gain)
            let nearer = landed.distance(to: target) < at.distance(to: target)
            // `landed != at` is what tells the two apart, and it is the whole difference
            // between a device that cannot do better and a cursor that will not go. One
            // count that moved the cursor and did not help is the end of the approach;
            // one count that moved it nowhere is a pinned cursor, and a pinned cursor
            // whose target is under two counts away would otherwise be reported as an
            // arrival it never made. [LAW:no-silent-failure]
            if !nearer, Self.isSmallest(step), landed != at { return reports + 1 }
            stalls = nearer ? 0 : stalls + 1
            guard stalls < Self.stalls else { throw WouldNotReach(target: target, cursor: landed, reports: reports + 1) }
            at = landed
        }
        throw WouldNotReach(target: target, cursor: at, reports: Self.rounds)
    }

    /// The cursor once it has left `before`, or wherever it is when the settle time is up.
    private func settled(from before: ScreenPoint) async throws -> ScreenPoint {
        try await settle { $0 != before }
    }

    /// The cursor, read every millisecond on `timeline` until `shown` says it shows what
    /// was sent or `settle` is up, whichever is first. The one wait on the window server
    /// applying a report. [LAW:single-enforcer]
    private func settle(until shown: (ScreenPoint) -> Bool) async throws -> ScreenPoint {
        let deadline = timeline.now() + Self.settle
        while true {
            let now = try await cursor()
            if shown(now) || timeline.now() >= deadline { return now }
            try await timeline.sleep(timeline.now() + .milliseconds(1))
        }
    }

    /// Moves to `point` and clicks `button` there `times` times, each click a report with
    /// the button down and one with everything up, each awaited.
    public func click(at point: ScreenPoint, button: Button, times: Clicks) async throws -> Click {
        do {
            let moved = try await move(to: point)
            let pressed = try await cursor()
            for _ in 0..<times.rawValue {
                try Task.checkCancellation()
                try await mouse.down(button)
                try await mouse.releaseAll()
            }
            return Click(at: pressed, moved: moved)
        } catch {
            throw PointingStopped(cause: error, unreleased: await release())
        }
    }

    /// How long the wheel rests after each notch.
    ///
    /// **A report is one notch to macOS, whatever count it carries, and notches closer
    /// together than this are accelerated.** Measured on studious (macOS 15) in Safari,
    /// TextEdit and Firefox, 2026-10-04: a report of 1, 10 or 30 scrolled as far as a report
    /// of 1, and so did 5 in Firefox. Ten one-count reports scrolled Safari 40 points at
    /// 150ms apart or slower - ten times one notch's 4 - and 239 points at 120ms, 560 at
    /// 100ms, 2572 back to back. TextEdit was accelerated at 140ms and not at 150ms;
    /// Firefox was at 100ms and not at 150ms. This is a third clear of that edge, so
    /// `--vertical N` scrolls N times as far as `--vertical 1`.
    public static let notchRest: Duration = .milliseconds(200)

    /// Moves to `point` and rolls the wheel there one notch at a time, a report each,
    /// resting `notchRest` after every one. Vertical positive away from the hand,
    /// horizontal positive to the right; a notch carries one count on each axis that has
    /// any left, so both axes roll together until the shorter is done.
    ///
    /// The rest follows the last notch too, so a roll started straight after this one is
    /// not taken by macOS as its continuation and accelerated.
    /// [LAW:dataflow-not-control-flow]
    ///
    /// **The counts are unbounded, and they used to be capped at a thousand.** The cap was
    /// there to stop a huge number posting reports until the process was killed, which is
    /// a real thing to want to stop and the wrong place to stop it: a document is as long
    /// as it is, and the device has no opinion about how far a wheel rolls. A roll that is
    /// longer than its caller wanted is stopped by cancelling it, which this loop asks
    /// about once per notch.
    public func scroll(at point: ScreenPoint, vertical: Int, horizontal: Int) async throws {
        do {
            try await move(to: point)
            for notch in 0..<max(vertical.magnitude, horizontal.magnitude) {
                try Task.checkCancellation()
                try await mouse.scroll(by: Scroll(vertical: Self.count(vertical, at: notch), horizontal: Self.count(horizontal, at: notch)))
                try await timeline.sleep(timeline.now() + Self.notchRest)
            }
        } catch {
            throw PointingStopped(cause: error, unreleased: await release())
        }
    }

    /// One count toward `total`'s sign while notch `notch` is still inside it, and none
    /// after. `magnitude` and not `abs`, which traps on `Int.min`.
    private static func count(_ total: Int, at notch: UInt) -> Count {
        Count(clamping: notch < total.magnitude ? total.signum() : 0)
    }

    /// A drag that finished: where the button went down, where it came up, and the move
    /// to the first and the carry to the second. Both places are read back, for the reason
    /// `Click.at` is. [FRAMING:representation]
    public struct Drag: Equatable, Sendable {
        public let from: ScreenPoint
        public let to: ScreenPoint
        public let approach: Moved
        public let carry: Moved
    }

    /// Moves to `start`, holds `button` down there, moves to `end` with it held, and lets
    /// every button go.
    ///
    /// The carry is the same trajectory as any move: the device's motion reports carry whatever
    /// buttons it is holding, so a move with a button down is a drag to macOS and needs
    /// nothing of its own. The release is `releaseAll` rather than the one button, for the
    /// reason `PointingDevice` has no `up`. [LAW:composability]
    public func drag(from start: ScreenPoint, to end: ScreenPoint, button: Button) async throws -> Drag {
        do {
            let approach = try await move(to: start)
            let pressed = try await cursor()
            try await mouse.down(button)
            let carry = try await move(to: end)
            let released = try await cursor()
            try await mouse.releaseAll()
            return Drag(from: pressed, to: released, approach: approach, carry: carry)
        } catch {
            throw PointingStopped(cause: error, unreleased: await release())
        }
    }

    /// Every button up, on the way out of a run that stopped, for the reason `Typist`'s
    /// release gives: a button the driver believes is down is a drag that continues.
    /// [LAW:no-silent-failure] A release that fails is reported beside the stop.
    func release(isolation: isolated (any Actor)? = #isolation) async -> (any Error)? {
        await failure(of: mouse.releaseAll)
    }
}

private extension ScreenPoint {
    /// The larger of the two axis distances: a move has arrived when both are small, so
    /// progress is the worse of the two getting better.
    func distance(to other: ScreenPoint) -> Double {
        max(abs(other.x - x), abs(other.y - y))
    }
}

/// The cursor did not reach the target: stalled, or still short after every report the
/// move was allowed.
public struct WouldNotReach: Error, CustomStringConvertible {
    public let target: ScreenPoint
    public let cursor: ScreenPoint
    public let reports: Int

    public var description: String { "the cursor would not reach \(target): it is at \(cursor) after \(reports) reports" }
}

public struct CursorUnreadable: Error, CustomStringConvertible {
    public init() {}

    public var description: String { "the window server would not say where the cursor is" }
}

/// The window server listed no display a cursor could be on: none at all, or one with no
/// area.
public struct DisplaysUnreadable: Error, CustomStringConvertible {
    public let frames: [CGRect]

    public init(frames: [CGRect]) { self.frames = frames }

    public var description: String { "the window server listed no displays a path could be kept on: \(frames)" }
}

/// A pointing run that stopped: vhidd went quiet, the caller cancelled it, or the
/// cursor would not go where it was sent. What stopped it is the cause; whether the
/// buttons are known to be up is the part the operator has to act on.
public struct PointingStopped: StoppedPartWay, CustomStringConvertible {
    public let cause: any Error
    /// The failure of the release that followed the stop, when it failed too. Nil says
    /// every button is up; anything else says one may be held, and macOS will drag it.
    public let unreleased: (any Error)?

    public init(cause: any Error, unreleased: (any Error)? = nil) {
        self.cause = cause
        self.unreleased = unreleased
    }

    public var description: String {
        Self.unreleased(unreleased, after: cause.reported)
    }

    /// `report`, and then that a button may be held when the mouse's release failed.
    static func unreleased(_ error: (any Error)?, after report: String) -> String {
        error.map { report.then("The mouse was not released afterwards: \($0.reported)").then("A button may be left held") } ?? report
    }
}

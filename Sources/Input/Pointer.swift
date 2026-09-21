import CoreGraphics
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
/// next delta from there - and it learns the gain as it goes: each step's observed motion
/// over its requested motion is the estimate the next request is divided by. The curve
/// grows with speed and the requests shrink as the target nears, so once the gain is
/// known each step undershoots rather than overshoots, and the loop converges from below.
/// [LAW:no-ambient-temporal-coupling] The cursor's position is the state the loop waits
/// on, never a sleep after a report.
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
    public let cursor: @Sendable () throws -> ScreenPoint

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

    public init(mouse: any Mouse, cursor: @escaping @Sendable () throws -> ScreenPoint) {
        self.mouse = mouse
        self.cursor = cursor
    }

    /// A click that landed: where, and how many motion reports it took to get there.
    public struct Click: Equatable, Sendable {
        public let at: ScreenPoint
        public let reports: Int
    }

    /// The cursor as the window server reports it: global coordinates, top-left origin,
    /// points. Readable without privilege.
    public static func screenCursor() throws -> ScreenPoint {
        guard let location = CGEvent(source: nil)?.location else { throw CursorUnreadable() }
        return ScreenPoint(x: location.x, y: location.y)
    }

    /// The next report toward `to` from `from`, given that the OS moves the cursor `gain`
    /// points per count: the remaining distance over the gain, rounded toward zero so a
    /// known gain undershoots, and clamped to the report's edge. Zero on an axis within
    /// half a point, which is arrived; otherwise at least one count in the target's
    /// direction, so a gain estimate too high to ask for a whole count still asks for
    /// something. That floor is the one place a known gain steps past the target - a
    /// remainder just over half a point under a large gain - and the next round's
    /// re-estimate takes it back. Pure. [LAW:decomposition]
    public static func step(from: ScreenPoint, to: ScreenPoint, gain: Double) -> Move {
        Move(x: step(to.x - from.x, gain), y: step(to.y - from.y, gain))
    }

    private static func step(_ distance: Double, _ gain: Double) -> Count {
        guard abs(distance) > 0.5 else { return .zero }
        let counts = min(Double(Count.limit), max(1, (abs(distance) / gain).rounded(.towardZero)))
        return Count(clamping: Int(distance < 0 ? -counts : counts))
    }

    /// The gain the last report showed: points moved per count asked. A report that moved
    /// the cursor nowhere says the estimate was too high to move a whole point, so it is
    /// halved, and the next request doubles until something moves.
    static func gain(after step: Move, from before: ScreenPoint, to after: ScreenPoint, previous: Double) -> Double {
        let asked = hypot(Double(step.x.value), Double(step.y.value))
        let moved = hypot(after.x - before.x, after.y - before.y)
        return moved > 0 ? moved / asked : previous / 2
    }

    /// Moves the cursor to `target`, within half a point on each axis, and answers with
    /// how many reports it took.
    ///
    /// Cancellation is checked once per round, which is once per report: the rounds are
    /// the only place this loop can be left without a button held, because every other
    /// line of it is a read. [LAW:dataflow-not-control-flow]
    @discardableResult
    public func move(to target: ScreenPoint) async throws -> Int {
        var at = try cursor()
        var gain = 1.0
        var stalls = 0
        for reports in 0..<Self.rounds {
            try Task.checkCancellation()
            let step = Self.step(from: at, to: target, gain: gain)
            guard step != .none else { return reports }
            try await mouse.move(by: step)
            let landed = try await settled(from: at)
            gain = Self.gain(after: step, from: at, to: landed, previous: gain)
            stalls = landed.distance(to: target) < at.distance(to: target) ? 0 : stalls + 1
            guard stalls < Self.stalls else { throw WouldNotReach(target: target, cursor: landed, reports: reports + 1) }
            at = landed
        }
        throw WouldNotReach(target: target, cursor: at, reports: Self.rounds)
    }

    /// The cursor once it has left `before`, or wherever it is when the settle time is up.
    private func settled(from before: ScreenPoint) async throws -> ScreenPoint {
        let deadline = ContinuousClock.now + Self.settle
        while true {
            let now = try cursor()
            if now != before || ContinuousClock.now >= deadline { return now }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Moves to `point` and clicks `button` there `times` times, each click a report with
    /// the button down and one with everything up, each awaited.
    public func click(at point: ScreenPoint, button: Button, times: Clicks) async throws -> Click {
        do {
            let reports = try await move(to: point)
            for _ in 0..<times.rawValue {
                try Task.checkCancellation()
                try await mouse.down(button)
                try await mouse.releaseAll()
            }
            return Click(at: point, reports: reports)
        } catch {
            throw PointingStopped(cause: error, unreleased: await release())
        }
    }

    /// Moves to `point` and rolls the wheel there, in as many reports as the counts take:
    /// a report carries at most 127 on an axis, so 300 is 127, 127 and 46. Vertical
    /// positive away from the hand, horizontal positive to the right.
    ///
    /// **The counts are unbounded, and they used to be capped at a thousand.** The cap was
    /// there to stop a huge number posting reports until the process was killed, which is
    /// a real thing to want to stop and the wrong place to stop it: a document is as long
    /// as it is, and the device has no opinion about how far a wheel rolls. A roll that is
    /// longer than its caller wanted is stopped by cancelling it, which this loop asks
    /// about once per report.
    public func scroll(at point: ScreenPoint, vertical: Int, horizontal: Int) async throws {
        do {
            try await move(to: point)
            var remaining = (vertical: vertical, horizontal: horizontal)
            while remaining != (0, 0) {
                try Task.checkCancellation()
                let chunk = Scroll(vertical: Count(clamping: remaining.vertical), horizontal: Count(clamping: remaining.horizontal))
                try await mouse.scroll(by: chunk)
                remaining = (remaining.vertical - Int(chunk.vertical.value), remaining.horizontal - Int(chunk.horizontal.value))
            }
        } catch {
            throw PointingStopped(cause: error, unreleased: await release())
        }
    }

    /// Every button up, on the way out of a run that stopped, for the reason `Typist`'s
    /// release gives: a button the driver believes is down is a drag that continues.
    /// [LAW:no-silent-failure] A release that fails is reported beside the stop.
    func release(isolation: isolated (any Actor)? = #isolation) async -> (any Error)? {
        do {
            try await mouse.releaseAll()
            return nil
        } catch {
            return error
        }
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
    public var description: String { "the window server would not say where the cursor is" }
}

/// A pointing run that stopped: the helper went quiet, the caller cancelled it, or the
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
        "\(cause.reported)" + (unreleased.map { ". The mouse was not released afterwards: \($0). A button may be left held" } ?? "")
    }
}

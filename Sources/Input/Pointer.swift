import CoreGraphics
import Foundation
import Pointing
import SystemConfiguration

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
    ///
    /// `at` is where the cursor was when the button went down, read back rather than
    /// repeated from the request. [FRAMING:representation] The move stops beside a target
    /// the device cannot land on exactly, so the point asked for and the point pressed are
    /// two different facts - and this is the one positional thing a caller is told, so it
    /// has to be the one that happened.
    public struct Click: Equatable, Sendable {
        public let at: ScreenPoint
        public let reports: Int
    }

    /// The cursor as the window server reports it: global coordinates, top-left origin,
    /// points. Readable without privilege, by the user in front of the screen or by root.
    public static func screenCursor() throws -> ScreenPoint {
        try windowServerCursor()()
    }

    /// The reader `screenCursor` uses, with the session settled once up front: a move reads
    /// the cursor every millisecond while a report settles, and asking configd who is in
    /// front each time would be thousands of round trips a move.
    public static func windowServerCursor() throws -> @Sendable () throws -> ScreenPoint {
        try sessionCursor(caller: geteuid(), console: ConsoleUser.current) { CGEvent(source: nil)?.location }
    }

    /// **The window server answers (0, 0) to anyone else, and not an error.** Measured on a
    /// second Mac (docs/design/remote-hands.md): SSH as a user who is not the one in front,
    /// or at the login window with nobody logged in, reads (0, 0) as though it were a
    /// position, and a move steering by it either stalls there or, for a target beside
    /// (0, 0), reports an arrival it never made. So who is asking is settled before the
    /// window server is, and the answer names who is in front. Root read the real position
    /// with bmf in front, so root passes. A read of exactly (0, 0) asks again, since the
    /// user in front can change during an hour of `play`. [LAW:no-silent-failure]
    static func sessionCursor(
        caller: uid_t, console: @escaping @Sendable () -> ConsoleUser?, location: @escaping @Sendable () -> CGPoint?
    ) throws -> @Sendable () throws -> ScreenPoint {
        let admit: @Sendable () throws -> Void = {
            guard let console = console() else { throw NoWindowServerSession(caller: caller, console: nil) }
            guard caller == console.uid || caller == 0 else { throw NoWindowServerSession(caller: caller, console: console) }
        }
        try admit()
        return {
            guard let location = location(), let cursor = ScreenPoint(x: location.x, y: location.y) else {
                throw CursorUnreadable()
            }
            if location == .zero { try admit() }
            return cursor
        }
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

    /// Moves the cursor to `target` and answers with how many reports it took.
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
    @discardableResult
    public func move(to target: ScreenPoint) async throws -> Int {
        var at = try cursor()
        var gain = Gain.assumed
        var stalls = 0
        for reports in 0..<Self.rounds {
            try Task.checkCancellation()
            let step = Self.step(from: at, to: target, gain: gain)
            guard step != .none else { return reports }
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
            let pressed = try cursor()
            for _ in 0..<times.rawValue {
                try Task.checkCancellation()
                try await mouse.down(button)
                try await mouse.releaseAll()
            }
            return Click(at: pressed, reports: reports)
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

    /// A drag that finished: where the button went down, where it came up, and how many
    /// motion reports the whole of it took. Both places are read back, for the reason
    /// `Click.at` is. [FRAMING:representation]
    public struct Drag: Equatable, Sendable {
        public let from: ScreenPoint
        public let to: ScreenPoint
        public let reports: Int
    }

    /// Moves to `start`, holds `button` down there, moves to `end` with it held, and lets
    /// every button go.
    ///
    /// The carry is the same loop as any move: the device's motion reports carry whatever
    /// buttons it is holding, so a move with a button down is a drag to macOS and needs
    /// nothing of its own. The release is `releaseAll` rather than the one button, for the
    /// reason `PointingDevice` has no `up`. [LAW:composability]
    public func drag(from start: ScreenPoint, to end: ScreenPoint, button: Button) async throws -> Drag {
        do {
            let approach = try await move(to: start)
            let pressed = try cursor()
            try await mouse.down(button)
            let carry = try await move(to: end)
            let released = try cursor()
            try await mouse.releaseAll()
            return Drag(from: pressed, to: released, reports: approach + carry)
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

/// The user in front of the screen: whose window-server session the cursor belongs to.
public struct ConsoleUser: Equatable, Sendable {
    public let name: String
    public let uid: uid_t

    public init(name: String, uid: uid_t) {
        self.name = name
        self.uid = uid
    }

    /// Who is logged in at the console, or nil at the login window, where macOS names the
    /// console's owner `loginwindow`, and when configd will not say.
    public static func current() -> ConsoleUser? {
        var uid: uid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?, name != "loginwindow" else { return nil }
        return ConsoleUser(name: name, uid: uid)
    }
}

/// The cursor belongs to a window-server session the caller is not in: nobody is logged
/// in, or somebody else is in front.
public struct NoWindowServerSession: Error, CustomStringConvertible {
    public let caller: uid_t
    /// Who is in front, or nil at the login window.
    public let console: ConsoleUser?

    public var description: String {
        guard let console else {
            return "nobody is logged in at this Mac's screen, or who is could not be read, so there is no window-server session to read the cursor from"
        }
        return "the cursor belongs to \(console.name)'s window-server session, and this process runs as uid \(caller): run vhid as \(console.name), with sudo launchctl asuser \(console.uid) sudo -u \(console.name)"
    }
}

public struct CursorUnreadable: Error, CustomStringConvertible {
    public var description: String { "the window server would not say where the cursor is" }
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

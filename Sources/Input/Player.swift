import Foundation
import Keystrokes
import Pointing
import ScreenSpace

/// What `vhid play` sends and when: a `Play` as one act per device call, on one clock.
///
/// [LAW:parse-dont-validate] Made from a `Play` before anything is connected, so a script
/// this cannot play is refused at its line and moves nothing. A line that restates the set
/// already held sends nothing, so it is not an act.
///
/// **Keys held through a quiet stretch are kept alive here, as acts.** vhidd lets go of
/// every key `HeldKeys.silenceLimit` after the client last spoke, so
/// Shift held for three seconds with nothing else happening would be cut. Wherever a key
/// is held and no act comes for `keepAlive`, the schedule repeats the held set; the daemon
/// counts the call as the client being alive and posts nothing for it, since the driver
/// already holds that set. A player stalled past the limit - stopped in a debugger, a Mac
/// asleep - has had its keys let go, and its next keep-alive presses them again, as a
/// report no report line shows. [LAW:dataflow-not-control-flow] The keep-alives are values in
/// the schedule the player walks like any other act, not a timer running beside it.
///
/// **A script of `at` lines is steered, and every click lands where it was recorded.**
/// Between clicks each `at` line is reports from a table measured before the clock starts
/// (`Steering`); before every buttons line and at the end the schedule has a `steer`, the
/// pointer's closed loop onto the last `at` point, which takes out whatever error the
/// table built up. Scripts of `move` lines have no steer and no calibration: their counts
/// are the input.
///
/// [LAW:parse-dont-validate] Its points are `Point`: a schedule is made from a script as
/// `ScreenPoint`s, before anything is connected, and `placed(on:)` puts every one of them on
/// the layout the play reads, before the first act, as `Placed<ScreenPoint>`s - the only
/// kind `Player` plays.
public struct Schedule<Point: Hashable & Sendable>: Hashable, Sendable {
    public let start: Point
    /// The script line the start was written on.
    public let startLine: Int
    public let acts: [Act]
    /// What to measure before the clock starts, when the script has `at` lines.
    public let calibration: Calibration<Point>?

    public struct Act: Hashable, Sendable {
        public let at: Duration
        public let report: Report
        /// The script line it came from; a keep-alive carries the line of the keys it
        /// repeats. A line that sends nothing has no act, so this and not an act's place is
        /// how a report is matched to the script.
        public let line: Int
    }

    /// One device call each.
    public enum Report: Hashable, Sendable {
        case keys(HeldKeys)
        case buttons(Set<Button>)
        case move(Move)
        case wheel(Scroll)
        /// The cursor should be here now: reports from the calibrated table, without
        /// reading the cursor.
        case at(Point)
        /// The keys already held, said again so the daemon keeps them. Not a report: the
        /// driver is sent nothing while it still holds them.
        case keepAlive(HeldKeys)
        /// The pointer's closed loop onto this point, however many reports it takes. Not a
        /// report of the script's, and the time it takes pushes every later act back.
        case steer(Point)

        var isReport: Bool {
            switch self {
            case .keepAlive, .steer: false
            case .keys, .buttons, .move, .wheel, .at: true
            }
        }
    }

    /// The longest a held key goes without a call: half vhidd's limit, so a keep-alive that
    /// goes out late still lands well inside it.
    public static var keepAlive: Duration { HeldKeys.silenceLimit / 2 }

    /// How many of the acts are reports, which is what a play that stops is counted against.
    public var reports: Int { acts.filter(\.report.isReport).count }

    /// Whether any of the first `count` acts holds a key, and so whether a play stopped
    /// there has a keyboard to let go of.
    func holdsKeys(in count: Int) -> Bool {
        acts.prefix(count).contains { if case .keys = $0.report { true } else { false } }
    }

    init(start: Point, startLine: Int, acts: [Act], calibration: Calibration<Point>?) {
        self.start = start
        self.startLine = startLine
        self.acts = acts
        self.calibration = calibration
    }
}

extension Schedule where Point == ScreenPoint {
    public init(_ play: Play) throws(Play.ScriptInvalid) {
        var keys = (held: HeldKeys.none, line: 0)
        var buttons: Set<Button> = []
        var acts: [Act] = []
        let points = play.events.compactMap { event in if case .at(let point) = event.report { (event.at, point, event.line) } else { nil } }
        // Where the steer before a click aims: the last at point, or the start before any.
        var aim = play.start
        // [LAW:dataflow-not-control-flow] A script of move lines steers nowhere: its steers
        // are an empty list, not a branch around them.
        let steer = { (at: Duration, line: Int) in points.isEmpty ? [] : [Act(at: at, report: .steer(aim), line: line)] }
        for event in play.events {
            var quiet = acts.last?.at ?? .zero
            while !keys.held.usages.isEmpty, event.at - quiet > Self.keepAlive {
                quiet += Self.keepAlive
                acts.append(Act(at: quiet, report: .keepAlive(keys.held), line: keys.line))
            }
            let report: Report
            switch event.report {
            case .keys(let next) where next == keys.held: continue
            case .keys(let next):
                keys = (next, event.line)
                report = .keys(next)
            case .buttons(let next) where next == buttons: continue
            case .buttons(let next):
                buttons = next
                report = .buttons(next)
                acts += steer(event.at, event.line)
            case .move(let delta): report = .move(delta)
            case .wheel(let delta): report = .wheel(delta)
            case .at(let point):
                aim = point
                report = .at(point)
            }
            acts.append(Act(at: event.at, report: report, line: event.line))
        }
        guard let last = acts.last else {
            throw Play.ScriptInvalid(line: play.events[0].line, reason: "no line of this script sends a report")
        }
        self.init(start: play.start, startLine: play.startLine, acts: acts + steer(last.at, last.line),
                  calibration: points.isEmpty ? nil : Calibration(start: (play.start, play.startLine), points: points))
    }

    /// Every point of the schedule on `displays`, by the rule every act is placed by, or the
    /// line of the first that no display holds. [LAW:single-enforcer]
    public func placed(on displays: Displays) throws(Play.ScriptInvalid) -> Schedule<Placed<ScreenPoint>> {
        try map { (point, line) throws(Play.ScriptInvalid) in
            do throws(Unplaced) { return try displays.place(point) } catch { throw Play.ScriptInvalid(line: line, reason: error.description) }
        }
    }
}

extension Schedule {
    /// The same schedule with every point it holds - the start, each at and steer act's, and
    /// where calibration heads - through `transform`, with the line it was written on.
    /// [LAW:one-source-of-truth] The one place a schedule's points are listed.
    func map<Other, Failure: Error>(_ transform: (Point, Int) throws(Failure) -> Other) throws(Failure) -> Schedule<Other> {
        var mapped: [Schedule<Other>.Act] = []
        for act in acts {
            mapped.append(.init(at: act.at, report: try act.report.map { (point) throws(Failure) in try transform(point, act.line) }, line: act.line))
        }
        return Schedule<Other>(start: try transform(start, startLine), startLine: startLine, acts: mapped,
                               calibration: try calibration?.map(transform))
    }
}

extension Schedule.Report {
    /// The same report with its point, if it has one, through `transform`.
    func map<Other, Failure: Error>(_ transform: (Point) throws(Failure) -> Other) throws(Failure) -> Schedule<Other>.Report {
        switch self {
        case .keys(let held): .keys(held)
        case .buttons(let held): .buttons(held)
        case .move(let delta): .move(delta)
        case .wheel(let delta): .wheel(delta)
        case .keepAlive(let held): .keepAlive(held)
        case .at(let point): .at(try transform(point))
        case .steer(let point): .steer(try transform(point))
        }
    }
}

/// The measurement `Steering` is made from, read off a script: distances and a direction,
/// and the point it heads for, placed as every other point of the schedule is.
public struct Calibration<Point: Hashable & Sendable>: Hashable, Sendable {
    /// How far apart the script's `at` lines are, the median gap: acceleration depends
    /// on the pace, so the table is measured at the pace it is used at.
    public let interval: Duration
    /// The longest step between two consecutive `at` points, in points: the ladder stops
    /// at the first report length that covers it.
    public let reach: Double
    /// The `at` point farthest from the start, which calibration heads for, so it moves
    /// the cursor where the recording went.
    public let toward: Point
    /// The script line `toward` was written on.
    public let towardLine: Int

    /// The gap assumed for a script with one `at` line, or all at one time: the 120 Hz
    /// a trackpad reports at.
    public static var pace: Duration { .microseconds(8333) }

    init(interval: Duration, reach: Double, toward: Point, towardLine: Int) {
        self.interval = interval
        self.reach = reach
        self.toward = toward
        self.towardLine = towardLine
    }

    /// The same calibration heading for `toward` through `transform`.
    func map<Other, Failure: Error>(_ transform: (Point, Int) throws(Failure) -> Other) throws(Failure) -> Calibration<Other> {
        Calibration<Other>(interval: interval, reach: reach, toward: try transform(toward, towardLine), towardLine: towardLine)
    }
}

extension Calibration where Point == ScreenPoint {
    init(start: (point: ScreenPoint, line: Int), points: [(at: Duration, point: ScreenPoint, line: Int)]) {
        let gaps = zip(points, points.dropFirst()).map { $1.at - $0.at }.filter { $0 > .zero }.sorted()
        let path: [(point: ScreenPoint, line: Int)] = [start] + points.map { ($0.point, $0.line) }
        let origin = start.point
        let farthest = path.max { hypot($0.point.x - origin.x, $0.point.y - origin.y) < hypot($1.point.x - origin.x, $1.point.y - origin.y) } ?? start
        self.init(interval: gaps.isEmpty ? Self.pace : gaps[gaps.count / 2],
                  reach: zip(path, path.dropFirst()).map { hypot($1.point.x - $0.point.x, $1.point.y - $0.point.y) }.max() ?? 0,
                  toward: farthest.point, towardLine: farthest.line)
    }
}

/// Plays a `Schedule` on the keyboard and the mouse: the pointer's loop to the start, then
/// every act at its offset from one start of the clock, recording when each report was
/// handed to its device and when the device acknowledged it.
///
/// [LAW:no-ambient-temporal-coupling] Each report waits for its own deadline measured
/// from the one start, never for a sleep after the report before it, so a report that
/// goes out late does not push every later one back. A late report is still sent, and
/// sent late: dropping it would change the input the replay exists to hold fixed, and
/// the lateness is recorded instead.
///
/// The clock is the pointer's `timeline` and the wall is taken as a value, so the schedule
/// runs against a clock a test moves by hand. [LAW:effects-at-boundaries]
/// [LAW:one-source-of-truth] The deadlines and the pointer's own waits are on one clock.
public struct Player {
    public let pointer: Pointer
    public let keyboard: any Keyboard
    /// Microseconds since the Unix epoch, read once, at the clock's start. Every time the
    /// run reports is that reading plus the monotonic clock's own elapsed time, so the
    /// times are on one clock a browser's `timeOrigin + now()` can be set against, and a
    /// wall-clock adjustment mid-run moves none of them. [LAW:one-source-of-truth]
    public let wall: () -> Int64
    /// How long before a deadline the sleep ends and the clock is watched instead, until
    /// the deadline comes: a sleep resumes late, by more the longer it slept, and a watch
    /// that is already there does not pay it.
    public let lead: Duration
    /// The longest a wait goes without asking whether the play may go on.
    static var slice: Duration { .milliseconds(50) }

    public init(pointer: Pointer, keyboard: any Keyboard, wall: @escaping () -> Int64, lead: Duration) {
        self.pointer = pointer
        self.keyboard = keyboard
        self.wall = wall
        self.lead = lead
    }

    /// Plays `script` once every point of it is placed on the one reading of the layout this
    /// play makes: a line no display holds is refused by number before anything moves. The
    /// layout is read again once the last report is out, and a play the displays changed
    /// under says so: a point placed before the change may have been on no display when its
    /// report went, and macOS holds the cursor at an edge without a word.
    /// [LAW:no-silent-failure]
    public func play(_ script: Schedule<ScreenPoint>, isolation: isolated (any Actor)? = #isolation) async throws -> Played {
        let play = try script.placed(on: try await pointer.displays())
        let timeline = pointer.timeline
        var went: [Played.Report] = []
        var reached = 0
        // The act being waited on or played, which a stop names.
        var line: Int?
        let startReports: Int
        do {
            var reports = try await pointer.home(on: play.start)
            // Measured before the clock starts, from the start, and the cursor brought back
            // to it after. [LAW:no-ambient-temporal-coupling] The table exists before any
            // at act can ask for it.
            var course: Course?
            if let calibration = play.calibration {
                let steering = try await pointer.calibrate(calibration, from: play.start)
                reports += try await pointer.home(on: play.start)
                // Read back: the loop stops beside a point it cannot land on.
                course = Course(steering: steering, interval: calibration.interval, at: try await pointer.cursor())
            }
            let started = timeline.now()
            let epoch = wall()
            let at = { (offset: Duration) in epoch + offset.microseconds }
            // How far the closed loops so far have pushed the script back. Timing is kept
            // between clicks, not across them.
            var delay = Duration.zero
            for (index, event) in play.acts.enumerated() {
                line = event.line
                let due = event.at + delay
                let deadline = started + due
                let wake = deadline - lead
                // A wait of any length is slices, each asking whether the run was
                // cancelled, so a cancelled play ends a long hold within a slice and not at
                // the next report. A deadline already inside the lead sleeps not at all,
                // since even a sleep that returns at once returns late.
                // [LAW:single-enforcer]
                while timeline.now() < wake {
                    try Task.checkCancellation()
                    try await timeline.sleep(min(wake, timeline.now() + Self.slice))
                }
                // The watch that follows the sleep. It asks the same question the sleep
                // did, because `lead` is the caller's to choose and nothing caps it: a long
                // one would otherwise be a stretch of every gap in which a cancelled play
                // kept spinning, the hole the slice loop above exists to close, reopened at
                // the last moment. [LAW:single-enforcer]
                //
                // And it watches a clock that may not be moving. Yielding until the
                // deadline is the whole point under a real clock - it is what keeps a
                // report inside the lead rather than the sleep's oversleep past it -
                // but a clock that only moves when something sleeps on it never reaches the
                // deadline, and the yield loop is then forever. So the watch measures
                // whether the clock is moving and sleeps when it is not, which needs
                // nothing declared about which kind was handed in.
                // [LAW:dataflow-not-control-flow] A real clock advances between two reads
                // separated by a yield, so this costs it nothing; if one ever did not, the
                // report lands where it would have landed with no lead at all.
                var watched = timeline.now()
                while timeline.now() < deadline {
                    try Task.checkCancellation()
                    await Task.yield()
                    guard timeline.now() != watched else {
                        try await timeline.sleep(deadline)
                        break
                    }
                    watched = timeline.now()
                }
                try Task.checkCancellation()
                let sent = timeline.now() - started
                // Counted before the post: one that throws may still have reached the driver.
                reached = index + 1
                // How many device reports this act sent: an at line sends what its step
                // takes, which may be none. [LAW:one-source-of-truth] The count a report
                // line stands for is what went to the device.
                var sentReports = 1
                switch event.report {
                case .steer(let point):
                    let current = try steered(course)
                    let began = timeline.now()
                    try await pointer.home(on: point)
                    delay += timeline.now() - began
                    course = Course(steering: current.steering, interval: current.interval, at: try await pointer.cursor())
                case .at(let point):
                    let current = try steered(course)
                    let (moves, lands) = try current.steering.reports(from: current.at, to: point)
                    // A step longer than one report is paced as the table was measured, so
                    // macOS accelerates each report as the table says.
                    for (number, move) in moves.enumerated() {
                        if number > 0 { try await timeline.sleep(timeline.now() + current.interval) }
                        try await pointer.mouse.move(by: move)
                    }
                    sentReports = moves.count
                    course = Course(steering: current.steering, interval: current.interval, at: lands)
                case .keys(let held), .keepAlive(let held): try await keyboard.hold(held)
                case .buttons(let held): try await pointer.mouse.hold(held)
                case .move(let delta): try await pointer.mouse.move(by: delta)
                case .wheel(let delta): try await pointer.mouse.scroll(by: delta)
                }
                let played = Played.Report(line: event.line, scheduled: at(due), sent: at(sent), acked: at(timeline.now() - started))
                went += event.report.isReport && sentReports > 0 ? [played] : []
            }
            startReports = reports
        } catch {
            // Both devices, whatever either answers, because a stop can land with a key and
            // a button both held. [LAW:no-silent-failure] A script that holds no key has no
            // keyboard to let go of, nor does one stopped before its first keys line, and a
            // failed release there would report a key held that never went down.
            // [LAW:dataflow-not-control-flow] The release is a value chosen from the acts
            // that were sent, as `Pointer.holding` chooses its own.
            let letGo: () async throws -> Void = play.holdsKeys(in: reached) ? { try await keyboard.releaseAll() } : {}
            let keys = await failure(of: letGo)
            throw PlayStopped(played: went, of: play.reports, line: line,
                              cause: error, unreleasedKeys: keys, unreleasedButtons: await pointer.release())
        }
        // Where the cursor can go, which is what a sleeping display does not change.
        let after = try await pointer.displays()
        return Played(startReports: startReports, reports: went, layoutChanged: after.frames != play.start.displays.frames)
    }

    /// Where the table thinks the cursor is, the table, and the pace it was measured at.
    private struct Course {
        let steering: Steering
        let interval: Duration
        let at: ScreenPoint
    }

    /// The course of a schedule that has at or steer acts, which is one that was
    /// calibrated. [LAW:types-are-the-program] exception: `Schedule` makes a calibration
    /// whenever it makes either act, and the type does not carry that, so a course missing
    /// here is a `Schedule` bug, said by name rather than trapped.
    private func steered(_ course: Course?) throws -> Course {
        guard let course else { throw Uncalibrated() }
        return course
    }

    struct Uncalibrated: Error, CustomStringConvertible {
        var description: String { "an at line came with no calibration to steer it by, which a Schedule never makes" }
    }
}

/// A play that went out whole: how many reports the loop took to reach the start, and
/// each scheduled report with its times.
public struct Played: Hashable, Sendable {
    public let startReports: Int
    public let reports: [Report]
    /// Whether the displays were somewhere else once the last report was out than where the
    /// play placed its points.
    public let layoutChanged: Bool

    /// One report's times, each in microseconds since the Unix epoch: when it was due,
    /// when it was handed to its device, and when the device acknowledged it, with the script
    /// line it came from. Reports go out in order and a stop ends the list rather than
    /// leaving a gap in it.
    public struct Report: Hashable, Sendable {
        public let line: Int
        public let scheduled: Int64
        public let sent: Int64
        public let acked: Int64
    }

    /// Nil for a play that sent no report: a script whose at lines all sat within a count
    /// of the cursor sends none, and has no lateness to rank.
    public var lateness: Lateness? { Lateness(of: reports.map { $0.sent - $0.scheduled }) }
}

/// How late reports went out, in microseconds, by nearest rank.
public struct Lateness: Hashable, Sendable, Encodable {
    public let p50: Int64
    public let p90: Int64
    public let p99: Int64
    public let max: Int64

    /// [LAW:parse-dont-validate] Nil for no reports, which have no rank to read.
    init?(of lateness: [Int64]) {
        guard !lateness.isEmpty else { return nil }
        let sorted = lateness.sorted()
        func rank(_ fraction: Double) -> Int64 { sorted[Swift.max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1)] }
        p50 = rank(0.5)
        p90 = rank(0.9)
        p99 = rank(0.99)
        max = rank(1)
    }
}

/// A play that stopped part way: the reports that went out before it did, of how many,
/// and why, with whether each device was released afterwards.
public struct PlayStopped: StoppedPartWay, CustomStringConvertible {
    public let played: [Played.Report]
    public let of: Int
    /// The script line being played when it stopped, or nil when it stopped before the
    /// first act: on the way to the start, or calibrating.
    public let line: Int?
    public let cause: any Error
    /// The failures of the releases that followed the stop, when they failed too. Nil says
    /// that device holds nothing; anything else says a key or a button may be held.
    public let unreleasedKeys: (any Error)?
    public let unreleasedButtons: (any Error)?

    public var description: String {
        let place = line.map { " at line \($0)" } ?? ""
        return PointingStopped.unreleased(unreleasedButtons, after: TypingStopped.unreleased(unreleasedKeys, after: "the play stopped\(place) after \(played.count) of \(of) reports: \(cause.reported)"))
    }
}

extension Duration {
    var microseconds: Int64 { components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000 }
}

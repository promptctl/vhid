import Foundation
import Pointing

/// A script the mouse alone can play: the start, then one report per act.
///
/// [LAW:parse-dont-validate] Made from a `Play` before anything is connected, so a script
/// this cannot hold is refused at its line and moves nothing. The mouse presses one button
/// or releases every one, so a `buttons` line is one report when it adds one button to
/// those held or releases them all. A line that adds several, one that lets go of some and
/// keeps others, a `keys` line and an `at` line need device acts the mouse does not have;
/// `docs/design/replay.md` gives them to `vhid play`. A line that restates the set already
/// held sends nothing, so it is not an act.
public struct MouseScript: Hashable, Sendable {
    public let start: ScreenPoint
    public let acts: [Act]

    public struct Act: Hashable, Sendable {
        public let at: Duration
        public let report: Report
        /// The script line it came from; a line that sends nothing has no act, so this and
        /// not an act's place is how a report is matched to the script.
        public let line: Int
    }

    /// What the mouse is asked to do, one report each.
    public enum Report: Hashable, Sendable {
        case move(Move)
        case wheel(Scroll)
        case press(Button)
        case releaseAll
    }

    public init(_ play: Play) throws(Play.ScriptInvalid) {
        var held: Set<Button> = []
        var acts: [Act] = []
        func refuse(_ event: Play.Timed, _ reason: String) -> Play.ScriptInvalid {
            Play.ScriptInvalid(line: event.line, reason: "\(reason), which the mouse alone cannot play")
        }
        for event in play.events {
            let report: Report
            switch event.report {
            case .move(let delta): report = .move(delta)
            case .wheel(let delta): report = .wheel(delta)
            case .buttons(let next) where next == held: continue
            case .buttons(let next) where next.isEmpty: report = .releaseAll
            case .buttons(let next) where next.isSuperset(of: held) && next.count == held.count + 1:
                report = .press(next.subtracting(held).first!)
            case .buttons(let next) where next.isSuperset(of: held): throw refuse(event, "this line presses \(next.count - held.count) buttons at once")
            case .buttons(let next) where next.isDisjoint(with: held): throw refuse(event, "this line lets go of every held button and presses others")
            case .buttons: throw refuse(event, "this line lets go of some buttons and keeps others held")
            case .keys: throw refuse(event, "this is a keys line")
            case .at: throw refuse(event, "this is an at line")
            }
            if case .buttons(let next) = event.report { held = next }
            acts.append(Act(at: event.at, report: report, line: event.line))
        }
        guard !acts.isEmpty else {
            throw Play.ScriptInvalid(line: play.events[0].line, reason: "no line of this script sends the mouse a report")
        }
        self.start = play.start
        self.acts = acts
    }
}

/// Plays a `MouseScript` on a mouse: the pointer's loop to the start, then every report at its
/// offset from one start of the clock, recording when each was handed to the mouse and
/// when the mouse acknowledged it.
///
/// [LAW:no-ambient-temporal-coupling] Each report waits for its own deadline measured
/// from the one start, never for a sleep after the report before it, so a report that
/// goes out late does not push every later one back. A late report is still sent, and
/// sent late: dropping it would change the input the replay exists to hold fixed, and
/// the lateness is recorded instead.
///
/// The clock and the wall are taken as values, so the schedule runs against a clock a
/// test moves by hand. [LAW:effects-at-boundaries]
public struct Player<C: Clock> where C.Duration == Duration {
    public let pointer: Pointer
    public let clock: C
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

    public init(pointer: Pointer, clock: C, wall: @escaping () -> Int64, lead: Duration) {
        self.pointer = pointer
        self.clock = clock
        self.wall = wall
        self.lead = lead
    }

    public func play(_ play: MouseScript, isolation: isolated (any Actor)? = #isolation) async throws -> Played {
        var went: [Played.Report] = []
        do {
            let reports = try await pointer.move(to: play.start)
            let started = clock.now
            let epoch = wall()
            let at = { (offset: Duration) in epoch + offset.microseconds }
            for event in play.acts {
                let deadline = started.advanced(by: event.at)
                let wake = deadline.advanced(by: .zero - lead)
                // A wait of any length is slices, each asking whether the run was
                // cancelled, so a cancelled play ends a long hold within a slice and not at
                // the next report. A deadline already inside the lead sleeps not at all,
                // since even a sleep that returns at once returns late.
                // [LAW:single-enforcer]
                while clock.now < wake {
                    try Task.checkCancellation()
                    try await clock.sleep(until: min(wake, clock.now.advanced(by: Self.slice)), tolerance: .zero)
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
                var watched = clock.now
                while clock.now < deadline {
                    try Task.checkCancellation()
                    await Task.yield()
                    guard clock.now != watched else {
                        try await clock.sleep(until: deadline, tolerance: .zero)
                        break
                    }
                    watched = clock.now
                }
                try Task.checkCancellation()
                let sent = started.duration(to: clock.now)
                try await post(event.report)
                went.append(Played.Report(line: event.line, scheduled: at(event.at), sent: at(sent), acked: at(started.duration(to: clock.now))))
            }
            return Played(startReports: reports, reports: went)
        } catch {
            throw PlayStopped(played: went, of: play.acts.count, cause: PointingStopped(cause: error, unreleased: await pointer.release()))
        }
    }

    private func post(_ report: MouseScript.Report, isolation: isolated (any Actor)? = #isolation) async throws {
        switch report {
        case .move(let delta): try await pointer.mouse.move(by: delta)
        case .wheel(let delta): try await pointer.mouse.scroll(by: delta)
        case .press(let button): try await pointer.mouse.down(button)
        case .releaseAll: try await pointer.mouse.releaseAll()
        }
    }
}

/// A play that went out whole: how many reports the loop took to reach the start, and
/// each scheduled report with its times.
public struct Played: Hashable, Sendable {
    public let startReports: Int
    public let reports: [Report]

    /// One report's times, each in microseconds since the Unix epoch: when it was due,
    /// when it was handed to the mouse, and when the mouse acknowledged it, with the script
    /// line it came from. Reports go out in order and a stop ends the list rather than
    /// leaving a gap in it.
    public struct Report: Hashable, Sendable {
        public let line: Int
        public let scheduled: Int64
        public let sent: Int64
        public let acked: Int64
    }

    public var lateness: Lateness { Lateness(of: reports.map { $0.sent - $0.scheduled }) }
}

/// How late reports went out, in microseconds, by nearest rank.
public struct Lateness: Hashable, Sendable, Encodable {
    public let p50: Int64
    public let p90: Int64
    public let p99: Int64
    public let max: Int64

    /// [LAW:parse-dont-validate] A `MouseScript` has at least one act, so a played one does too
    /// and there is always a rank to read; the empty case is the caller's precondition.
    init(of lateness: [Int64]) {
        let sorted = lateness.sorted()
        func rank(_ fraction: Double) -> Int64 { sorted[Swift.max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1)] }
        p50 = rank(0.5)
        p90 = rank(0.9)
        p99 = rank(0.99)
        max = rank(1)
    }
}

/// A play that stopped part way: the reports that went out before it did, of how many,
/// and why, with whether the buttons were released afterwards under the cause.
public struct PlayStopped: StoppedPartWay, CustomStringConvertible {
    public let played: [Played.Report]
    public let of: Int
    public let cause: any Error

    public var description: String { "the play stopped after \(played.count) of \(of) reports: \(cause.reported)" }
}

extension Duration {
    var microseconds: Int64 { components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000 }
}

import Foundation
import Keystrokes
import Pointing

/// What `vhid play` sends and when: a `Play` as one act per device call, on one clock.
///
/// [LAW:parse-dont-validate] Made from a `Play` before anything is connected, so a script
/// this cannot play is refused at its line and moves nothing. A line that restates the set
/// already held sends nothing, so it is not an act.
///
/// **Keys held through a quiet stretch are kept alive here, as acts.** vhidd lets go of
/// every key two seconds after the client last spoke (`Devices.keyLimit` in vhidd), so
/// Shift held for three seconds with nothing else happening would be cut. Wherever a key
/// is held and no act comes for `keepAlive`, the schedule repeats the held set; the daemon
/// counts the call as the client being alive and posts nothing for it, since the driver
/// already holds that set. [LAW:dataflow-not-control-flow] The keep-alives are values in
/// the schedule the player walks like any other act, not a timer running beside it.
public struct Schedule: Hashable, Sendable {
    public let start: ScreenPoint
    public let acts: [Act]

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
        /// The keys already held, said again so the daemon keeps them. Not a report: the
        /// driver is sent nothing.
        case keepAlive(HeldKeys)

        var isReport: Bool {
            if case .keepAlive = self { false } else { true }
        }
    }

    /// The longest a held key goes without a call: half vhidd's two-second limit, so a
    /// keep-alive that goes out late still lands well inside it.
    public static let keepAlive: Duration = .seconds(1)

    /// How many of the acts are reports, which is what a play that stops is counted against.
    public var reports: Int { acts.filter(\.report.isReport).count }

    public init(_ play: Play) throws(Play.ScriptInvalid) {
        var keys = (held: HeldKeys.none, line: 0)
        var buttons: Set<Button> = []
        var acts: [Act] = []
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
            case .move(let delta): report = .move(delta)
            case .wheel(let delta): report = .wheel(delta)
            case .at:
                throw Play.ScriptInvalid(line: event.line, reason: "vhid play does not steer to at lines; move the pointer with move lines")
            }
            acts.append(Act(at: event.at, report: report, line: event.line))
        }
        guard !acts.isEmpty else {
            throw Play.ScriptInvalid(line: play.events[0].line, reason: "no line of this script sends a report")
        }
        self.start = play.start
        self.acts = acts
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
/// The clock and the wall are taken as values, so the schedule runs against a clock a
/// test moves by hand. [LAW:effects-at-boundaries]
public struct Player<C: Clock> where C.Duration == Duration {
    public let pointer: Pointer
    public let keyboard: any Keyboard
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

    public init(pointer: Pointer, keyboard: any Keyboard, clock: C, wall: @escaping () -> Int64, lead: Duration) {
        self.pointer = pointer
        self.keyboard = keyboard
        self.clock = clock
        self.wall = wall
        self.lead = lead
    }

    public func play(_ play: Schedule, isolation: isolated (any Actor)? = #isolation) async throws -> Played {
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
                let played = Played.Report(line: event.line, scheduled: at(event.at), sent: at(sent), acked: at(started.duration(to: clock.now)))
                went += event.report.isReport ? [played] : []
            }
            return Played(startReports: reports, reports: went)
        } catch {
            // Both devices, whatever either answers, because a stop can land with a key and
            // a button both held. [LAW:no-silent-failure]
            let keys = await failure(of: keyboard.releaseAll)
            throw PlayStopped(played: went, of: play.reports, cause: error, unreleasedKeys: keys, unreleasedButtons: await pointer.release())
        }
    }

    private func post(_ report: Schedule.Report, isolation: isolated (any Actor)? = #isolation) async throws {
        switch report {
        case .keys(let held), .keepAlive(let held): try await keyboard.hold(held)
        case .buttons(let held): try await pointer.mouse.hold(held)
        case .move(let delta): try await pointer.mouse.move(by: delta)
        case .wheel(let delta): try await pointer.mouse.scroll(by: delta)
        }
    }
}

/// A play that went out whole: how many reports the loop took to reach the start, and
/// each scheduled report with its times.
public struct Played: Hashable, Sendable {
    public let startReports: Int
    public let reports: [Report]

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

    public var lateness: Lateness { Lateness(of: reports.map { $0.sent - $0.scheduled }) }
}

/// How late reports went out, in microseconds, by nearest rank.
public struct Lateness: Hashable, Sendable, Encodable {
    public let p50: Int64
    public let p90: Int64
    public let p99: Int64
    public let max: Int64

    /// [LAW:parse-dont-validate] A `Schedule` has at least one report, so a played one does too
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
/// and why, with whether each device was released afterwards.
public struct PlayStopped: StoppedPartWay, CustomStringConvertible {
    public let played: [Played.Report]
    public let of: Int
    public let cause: any Error
    /// The failures of the releases that followed the stop, when they failed too. Nil says
    /// that device holds nothing; anything else says a key or a button may be held.
    public let unreleasedKeys: (any Error)?
    public let unreleasedButtons: (any Error)?

    public var description: String {
        var said = "the play stopped after \(played.count) of \(of) reports: \(cause.reported)"
        if let keys = unreleasedKeys { said = said.then("The keyboard was not released afterwards: \(keys.reported)").then("A key may be left held") }
        if let buttons = unreleasedButtons { said = said.then("The mouse was not released afterwards: \(buttons.reported)").then("A button may be left held") }
        return said
    }
}

extension Duration {
    var microseconds: Int64 { components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000 }
}

import ArgumentParser
import Foundation
import Input

/// Replays a script of keyboard and mouse acts at fixed times, and says when each report
/// went out.
///
/// It exists for replaying what hands did - held keys, held buttons and motion on one
/// clock - and for a harness measuring what happens on screen while input is arriving: a
/// browser's own automation posts wheel events it coalesces and timestamps on a clock of
/// its own, and these reports are hardware to macOS, so they arrive the way a person's
/// do. The times are collected during the play and printed after it, so writing them is
/// never what makes a report late. [LAW:effects-at-boundaries]
struct PlayCommand: AsyncParsableCommand {
    static let configuration = Help.play.configuration

    @OptionGroup var service: ServiceOption

    func run() async throws {
        let ending: Ending
        do {
            // [LAW:parse-dont-validate] Parsed before anything is connected or moved, so a
            // script that cannot be played whole moves nothing.
            let schedule = try Self.schedule(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
            ending = .finished(try await Devices.using(try service.installation()) { try await Self.play(schedule, with: $0) })
        } catch {
            // The reports that did go out are printed even for a run that stopped, so a
            // harness can see how far it got. [LAW:no-silent-failure]
            for line in try Self.lines(of: .stopped((error as? PlayStopped)?.played ?? [])) { print(line) }
            throw error
        }
        for line in try Self.lines(of: ending) { print(line) }
    }

    /// A script's text as what the player sends, refused whole or not at all.
    static func schedule(_ text: String) throws -> Schedule {
        try Schedule(Play.parse(text))
    }

    /// The verb itself, over devices from anywhere. [LAW:decomposition]
    static func play(_ schedule: Schedule, with devices: Devices) async throws -> Played {
        try await Player(pointer: devices.pointer, keyboard: devices.keyboard, clock: ContinuousClock(), wall: epochMicroseconds, lead: lead).play(schedule)
    }

    /// What a play left behind: the reports that went out, and - only when it finished -
    /// the run to summarise.
    ///
    /// [LAW:dataflow-not-control-flow] "A play that stops prints no done line, and the
    /// missing line is what says it stopped" used to be a property of which of two catch
    /// arms did the printing, which is why nothing could check it without a daemon and a
    /// stoppage to provoke. Here it is a property of the value: a stopped play carries no
    /// `Played`, so there is no done line to be made and no path that makes one.
    ///
    /// **`finished` holds a play that sent something, and the type system is what says
    /// so.** `Played`'s initialiser is internal to `Input`, so the only one this target
    /// can hold is one `Player.play` returned, and a `Schedule` carries at least one report by
    /// construction - which is the precondition `Lateness` documents and relies on. There
    /// is therefore no guard here against an empty finished play: it cannot be spelled
    /// from outside `Input`, and a guard would have to invent a meaning for a done line
    /// with no lateness in it. [LAW:no-defensive-null-guards] [LAW:comments-carry-meaning]
    /// A test reaching through `@testable import Input` can of course build one, and that
    /// is the test stepping outside the guarantee rather than the guarantee being weak.
    enum Ending {
        case finished(Played)
        case stopped([Played.Report])

        var reports: [Played.Report] {
            switch self {
            case .finished(let played): played.reports
            case .stopped(let reports): reports
            }
        }
    }

    /// Every line this verb prints, as a value rather than as an effect.
    ///
    /// [LAW:decomposition] The other three verbs each keep what they do apart from where
    /// their devices came from; this one did not, and the whole documented contract above
    /// - the two envelopes, the snake_case keys, the lateness percentiles, the missing
    /// done line - was reachable only by running a daemon. Rendering is the part with the
    /// contract, and it needs no daemon, no clock and no mouse to answer for itself.
    static func lines(of ending: Ending) throws -> [String] {
        var lines = try ending.reports.enumerated().map { index, report in
            try line(ReportLine(report: .init(index: index, line: report.line, scheduledUs: report.scheduled,
                                              sentUs: report.sent, ackedUs: report.acked)))
        }
        if case .finished(let played) = ending {
            lines.append(try line(DoneLine(done: .init(reports: played.reports.count,
                                                       startReports: played.startReports,
                                                       lateUs: played.lateness))))
        }
        return lines
    }

    /// How early each report is woken for. `Player` sleeps until this much before the
    /// report is due and then watches the clock, so what the lead covers is however late
    /// the sleep itself comes back.
    ///
    /// **Measured rather than inherited, and the first answer was wrong.** The guess was
    /// that this process would need less than low-talker's 2500 us, since low-talker
    /// blames the hop back onto the main actor and these commands are nonisolated. That
    /// is not what oversleep is made of here. A bare `mach_wait_until` on the main thread
    /// of a script - no Swift concurrency anywhere near it - came back 505 us late for a
    /// 1 ms wait, 2505 us for 5 ms and 7781 us for 20 ms, and `nanosleep` and
    /// `Thread.sleep` came back within 3 us of it. It is not the resume. It grows with
    /// the wait, and with how idle the core has gone: the same 5 ms wait measured 1255 us
    /// late in a loop that kept the CPU busy between sleeps and 2505 us late in one that
    /// did not.
    ///
    /// Nor is it the clock. `WakingClock` (last in 071a2d4) blocked a thread in
    /// `mach_wait_until` for this. Interleaved with `ContinuousClock.sleep`, 150 of each
    /// per gap, two runs, on battery on 2026-09-27, p50 lateness was WakingClock's 265 and
    /// 266 us against 281 and 286 at 1 ms, 1271/1269 against 1035/1281 at 5 ms, 1800/1908
    /// against 1968/1705 at 8 ms, and 4802/4495 against 3909/3412 at 20 ms. Neither led:
    /// each was sooner in some rows and later in others, by up to a millisecond, so it
    /// went. Not rerun on AC.
    ///
    /// So no fixed number covers every gap a script can have, and this one does not
    /// pretend to. It is the bare script's 2505 us at 5 ms with an idle core - a p50,
    /// on AC, 2026-09-21 - the neighbourhood most scripts sit in, and what it fails to cover is not hidden: a report that goes out late goes out
    /// late and says so in `late_us`, which is the number a harness came here to read.
    /// [LAW:no-silent-failure]
    static let lead: Duration = .microseconds(2500)

    /// The wall clock, in the unit the lines are in.
    static func epochMicroseconds() -> Int64 {
        var now = timespec()
        clock_gettime(CLOCK_REALTIME, &now)
        return Int64(now.tv_sec) * 1_000_000 + Int64(now.tv_nsec) / 1000
    }

    private static let encoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static func line(_ encodable: some Encodable) throws -> String {
        String(decoding: try encoder.encode(encodable), as: UTF8.self)
    }

    private struct ReportLine: Encodable {
        let report: Times

        struct Times: Encodable {
            let index: Int
            let line: Int
            let scheduledUs: Int64
            let sentUs: Int64
            let ackedUs: Int64
        }
    }

    private struct DoneLine: Encodable {
        let done: Done

        struct Done: Encodable {
            let reports: Int
            let startReports: Int
            let lateUs: Lateness
        }
    }
}

import ArgumentParser
import Foundation
import Input

/// The virtual mouse driven report by report, for measuring what input does rather than
/// for getting something clicked.
struct PointerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pointer",
        abstract: "Drive the virtual mouse report by report.",
        subcommands: [PlayCommand.self])
}

/// Replays a script of raw mouse reports at fixed times, and says when each one went out.
///
/// It exists for a harness measuring what happens on screen while input is arriving: a
/// browser's own automation posts wheel events it coalesces and timestamps on a clock of
/// its own, and these reports are hardware to macOS, so they arrive the way a person's
/// do. The times are collected during the play and printed after it, so writing them is
/// never what makes a report late. [LAW:effects-at-boundaries]
struct PlayCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "play",
        abstract: "Replay a timed script of raw mouse reports from stdin, and print when each went out.",
        discussion: """
            The script is JSON Lines on stdin. The first line is where the cursor starts, reached \
            before the clock starts: {"to":{"x":800,"y":500}}, in screen points from the top left of \
            the main display. Every line after it is one report at t_ms milliseconds from the clock's \
            start, in order:
              {"t_ms":0,"down":"left"}               a button down: left, right, middle, or 1 to 32
              {"t_ms":8.3,"move":{"dx":4,"dy":-2}}   relative motion in counts, -127 to 127, uncorrected
              {"t_ms":16.7,"wheel":{"v":-1,"h":0}}   wheel ticks, -127 to 127; v positive scrolls content up
              {"t_ms":1000,"up":true}                every button up
            A script is refused whole, before the cursor moves, if a line is malformed, t_ms goes \
            backwards or past an hour, or it ends with a button held.

            Stdout is JSON Lines: one {"report":{"index":…,"scheduled_us":…,"sent_us":…,"acked_us":…}} \
            per report, times in microseconds since the Unix epoch, then \
            {"done":{"reports":…,"start_reports":…,"late_us":{"p50":…,"p90":…,"p99":…,"max":…}}}, \
            lateness being sent minus scheduled. A late report is sent late, never skipped.

            A play that stops releases every button, prints the reports that did go out, and prints no \
            done line - the missing done line is what says it stopped.
            """)

    @OptionGroup var service: ServiceOption

    func run() async throws {
        let ending: Ending
        do {
            // [LAW:parse-dont-validate] Parsed before anything is connected or moved, so a
            // script that cannot be played whole moves nothing.
            let play = try Play.parse(String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self))
            let pointer = Devices(of: try service.installation()).pointer
            let player = Player(pointer: pointer, clock: WakingClock(), wall: Self.epochMicroseconds, lead: Self.lead)
            ending = .finished(try await player.play(play))
        } catch {
            // The reports that did go out are printed even for a run that stopped, so a
            // harness can see how far it got. [LAW:no-silent-failure]
            for line in try Self.lines(of: .stopped((error as? PlayStopped)?.played ?? [])) { print(line) }
            throw error
        }
        for line in try Self.lines(of: ending) { print(line) }
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
    /// can hold is one `Player.play` returned, and a `Play` carries at least one report by
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
            try line(ReportLine(report: .init(index: index, scheduledUs: report.scheduled,
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
    /// So no fixed number covers every gap a script can have, and this one does not
    /// pretend to. It is the measured p99 for the 5 ms neighbourhood most scripts sit in,
    /// and what it fails to cover is not hidden: a report that goes out late goes out
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

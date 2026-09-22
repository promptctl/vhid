import Testing
@testable import Input
@testable import vhid

/// The lines `pointer play` prints, which are the largest contract this CLI makes and the
/// only one another program parses. Asserted whole rather than by key, because a harness
/// reads the whole line: the envelope names, the snake_case, the percentile keys and the
/// ordering are all part of what was promised.
///
/// [LAW:behavior-not-structure] No daemon, no clock and no mouse: rendering is the part
/// with the contract, and it can answer for itself.
///
/// `@testable import Input` is what reaches `Played`'s memberwise initialiser, which is
/// internal. Making it public to spare a test that keyword would be adding API to a
/// shipped library for the test's convenience. [LAW:carrying-cost]
@Suite struct PlayLinesTests {
    static func report(_ scheduled: Int64, _ sent: Int64, _ acked: Int64) -> Played.Report {
        Played.Report(scheduled: scheduled, sent: sent, acked: acked)
    }

    @Test func aFinishedPlayPrintsALinePerReportAndThenADoneLine() throws {
        let played = Played(startReports: 4, reports: [Self.report(1_000, 1_050, 1_090), Self.report(2_000, 2_500, 2_600)])
        let lines = try PlayCommand.lines(of: .finished(played))
        #expect(lines == [
            #"{"report":{"acked_us":1090,"index":0,"scheduled_us":1000,"sent_us":1050}}"#,
            #"{"report":{"acked_us":2600,"index":1,"scheduled_us":2000,"sent_us":2500}}"#,
            #"{"done":{"late_us":{"max":500,"p50":50,"p90":500,"p99":500},"reports":2,"start_reports":4}}"#,
        ])
    }

    /// The command's own discussion promises it: "A play that stops releases every button,
    /// prints the reports that did go out, and prints no done line - the missing done line
    /// is what says it stopped." A stopped play has no `Played` to summarise, so there is
    /// no path that could print one. [LAW:dataflow-not-control-flow]
    @Test func aStoppedPlayPrintsItsReportsAndNoDoneLine() throws {
        let lines = try PlayCommand.lines(of: .stopped([Self.report(1_000, 1_050, 1_090)]))
        #expect(lines == [#"{"report":{"acked_us":1090,"index":0,"scheduled_us":1000,"sent_us":1050}}"#])
        #expect(!lines.contains { $0.contains("done") })
    }

    /// A play that stopped before its first report prints nothing at all, which is the
    /// same signal as the missing done line rather than a different one.
    @Test func aPlayThatStoppedBeforeAnyReportPrintsNothing() throws {
        #expect(try PlayCommand.lines(of: .stopped([])).isEmpty)
    }

    /// The index is the report's place in the script, and a stopped play ends the list
    /// rather than leaving a gap in it, so the two agree without being made to.
    @Test func reportsAreNumberedByTheirPlaceInTheScript() throws {
        let lines = try PlayCommand.lines(of: .stopped((0..<3).map { Self.report(Int64($0), Int64($0), Int64($0)) }))
        #expect(lines.enumerated().allSatisfy { $1.contains("\"index\":\($0)") })
    }
}

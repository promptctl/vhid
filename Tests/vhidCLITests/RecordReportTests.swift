import RecordingTie
import Telemetry
import TelemetryTesting
import Testing
@testable import vhid

/// What a finished recording leaves on the record: how it ended and what it left out, each
/// count zeros included, so a recording that lost moves is told from one that lost none.
@Suite(.eventsKept) struct RecordReportTests {
    @Test func aFinishedRecordingSaysHowItEndedAndWhatItLeftOut() async {
        let collected = Collected()
        let recorded = Recorded(script: "", ending: .tapOff("too slow"), unmapped: 1, offDisplays: 2, vhidAtEdge: 0, layoutChanges: 3)
        await Telemetry.$export.withValue(collected.export) {
            await Telemetry.unit("record") { RecordCommand.report(recorded) }
        }
        let record = collected.all.first
        #expect(record?.attributes["ending"] == .string(recorded.ending.said))
        #expect(record?.attributes["left_out"] == .object(["unmapped": 1, "off_displays": 2, "vhid_at_edge": 0, "layout_changes": 3]))
    }
}

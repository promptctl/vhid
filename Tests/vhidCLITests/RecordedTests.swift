import Foundation
import RecordingTie
import Telemetry
import TelemetryTesting
import Testing
@testable import vhid

/// What `vhid record` makes of the tap app's messages: its notes said, its summary on the
/// record, its script the answer.
@Suite struct RecordedTests {
    /// A recording that ended with the tap at no place says so on its record, with what it
    /// left out, and the notes before it are said in order; the script is what it answers.
    @Test func aRecordingsRecordSaysHowItEndedAndWhatItLeftOut() async throws {
        let collected = Collected()
        let summary = Summary(ending: .tapAtNoPlace, unmappedKeys: 1, vhidAtEdge: 2, unplacedMoves: 3)
        var messages: [FromApp] = [.note("left 3 moves out"), .summary(summary), .script("{\"to\":{\"x\":1,\"y\":1}}")]
        var said: [String] = []
        let script = try await Telemetry.$export.withValue(collected.export) {
            try await Telemetry.unit("record") {
                try RecordCommand.recorded(next: { messages.isEmpty ? nil : messages.removeFirst() }, say: { said.append($0) })
            }
        }
        #expect(script == "{\"to\":{\"x\":1,\"y\":1}}")
        #expect(said == ["left 3 moves out"])
        let record = try #require(try collected.written.first)
        let recording = try #require((record["attributes"] as? [String: Any])?["recording"] as? [String: Any])
        #expect(recording["ending"] as? String == "tap_at_no_place")
        #expect(recording["unmapped_keys"] as? Int == 1)
        #expect(recording["vhid_at_edge"] as? Int == 2)
        #expect(recording["unplaced_moves"] as? Int == 3)
    }

    /// The tap app ending before the script is a failure by name, not an empty recording.
    @Test func aRecordingThatEndsWithoutItsScriptFails() {
        #expect { try RecordCommand.recorded(next: { nil }, say: { _ in }) } throws: { "\($0)" == "the tap app ended without sending the recording" }
    }
}

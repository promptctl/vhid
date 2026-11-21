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
    /// left out; the notes before it are said in order, then the summary's, worded from the
    /// counts the record holds; the script is what it answers.
    @Test func aRecordingsRecordSaysHowItEndedAndWhatItLeftOut() async throws {
        let collected = Collected()
        let summary = Summary(ending: .tapAtNoPlace, unmappedKeys: 1, vhidAtEdge: 0, unplacedMoves: 3)
        var messages: [FromApp] = [.note("the tap gave an event at no place"), .recorded(summary, script: "{\"to\":{\"x\":1,\"y\":1}}")]
        var said: [String] = []
        let script = try await Telemetry.$export.withValue(collected.export) {
            try await Telemetry.unit("record") {
                try RecordCommand.recorded(next: { messages.isEmpty ? nil : messages.removeFirst() }, say: { said.append($0) })
            }
        }
        #expect(script == "{\"to\":{\"x\":1,\"y\":1}}")
        #expect(said == ["the tap gave an event at no place",
                         "1 key presses with no HID usage, fn among them, are not in the recording",
                         "3 of the person's moves were on no display once vhid's motion was taken out, and are not in the recording"])
        let record = try #require(try collected.written.first)
        let recording = try #require((record["attributes"] as? [String: Any])?["recording"] as? [String: Any])
        #expect(recording["ending"] as? String == "tap_at_no_place")
        #expect(recording["unmapped_keys"] as? Int == 1)
        #expect(recording["vhid_at_edge"] as? Int == 0)
        #expect(recording["unplaced_moves"] as? Int == 3)
    }

    /// The tap app ending before the script is a failure by name, not an empty recording.
    @Test func aRecordingThatEndsWithoutItsScriptFails() {
        #expect { try RecordCommand.recorded(next: { nil }, say: { _ in }) } throws: { "\($0)" == "the tap app ended without sending the recording" }
    }
}

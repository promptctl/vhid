import Foundation
import Synchronization
import Telemetry
import Testing

/// Every event a unit of work emitted, collected in place of the edge.
final class Collected: Sendable {
    private let events = Mutex<[Event]>([])
    var all: [Event] { events.withLock { $0 } }
    var export: Telemetry.Export { { event in self.events.withLock { $0.append(event) } } }
}

struct TelemetryTests {
    struct Refusal: Error {}

    /// A unit emits one event however it ends, with what was noted and counted inside it.
    @Test func aUnitEmitsOnceHoweverItEnds() async throws {
        let collected = Collected()
        try await Telemetry.$export.withValue(collected.export) {
            _ = await Telemetry.unit("ok", outcome: { $0 ? "yes" : "no" }) {
                Telemetry.note("who", "me"); Telemetry.count("seen", 0); return true
            }
            await #expect(throws: Refusal.self) { try await Telemetry.unit("fails") { throw Refusal() } }
        }
        let events = collected.all
        #expect(events.map(\.event) == ["ok", "fails"])
        #expect(events[0].outcome == "yes" && events[0].error == nil)
        #expect(events[0].facts == ["who": "me"] && events[0].counts == ["seen": 0])
        #expect(events[1].outcome == "error" && events[1].error == "Refusal()")
        #expect(events.allSatisfy { $0.service == "eyes" && $0.traceID.count == 32 && $0.durationMs >= 0 })
        #expect(events[0].traceID != events[1].traceID)
    }

    /// A unit inside another shares its trace.
    @Test func aUnitInsideAnotherSharesItsTrace() async {
        let collected = Collected()
        await Telemetry.$export.withValue(collected.export) {
            await Telemetry.unit("outer") { await Telemetry.unit("inner") {} }
        }
        #expect(collected.all.map(\.event) == ["inner", "outer"])
        #expect(Set(collected.all.map(\.traceID)).count == 1)
    }

    /// One event, as a unit emits it.
    private func event() async -> Event {
        let collected = Collected()
        await Telemetry.$export.withValue(collected.export) { await Telemetry.unit("e") {} }
        return collected.all[0]
    }

    private func lines(_ file: URL) throws -> [[String: Any]] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
            .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    /// With no collector the record goes to the file, and was never a failure; with one
    /// that cannot take it, the file record carries why.
    @Test func theEdgeFallsBackToTheFileAndSaysWhy() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "eyes-\(UUID())/events.jsonl")
        let e = await event()
        let quiet = await Edge(collector: nil, file: file).send(e)
        #expect(quiet.sink == .file && quiet.sinkError == nil)
        let refused = await Edge(collector: URL(string: "http://127.0.0.1:9")!, file: file).send(e)
        #expect(refused.sink == .file && refused.sinkError != nil)
        let written = try lines(file)
        #expect(written.count == 2)
        #expect(written[0]["sink"] as? String == "file" && written[0]["sink_error"] == nil)
        #expect(written[1]["sink_error"] is String)
        #expect(written.allSatisfy { $0["event"] as? String == "e" && $0["trace_id"] is String && $0["duration_ms"] is Double
            && $0["started_at"] is String && $0["counts"] is [String: Any] })
    }
}

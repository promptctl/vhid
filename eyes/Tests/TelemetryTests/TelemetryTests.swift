import Foundation
@testable import Telemetry
import TelemetryTesting
import Testing

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

    /// A unit withdrawn by cancellation says so, and a tally says how far it got.
    @Test func aCancelledUnitSaysSoAndHowFarItGot() async {
        let collected = Collected()
        let started = AsyncStream<Void>.makeStream()
        let unit = Task {
            await Telemetry.$export.withValue(collected.export) {
                try? await Telemetry.unit("withdrawn") {
                    Telemetry.tally("reads"); Telemetry.tally("reads")
                    started.continuation.finish()
                    try await Task.sleep(for: .seconds(60))
                }
            }
        }
        for await _ in started.stream {}
        unit.cancel()
        await unit.value
        #expect(collected.all.map(\.outcome) == ["cancelled"])
        #expect(collected.all[0].counts == ["reads": 2])
    }

    /// The OTLP record carries every field the file line does, in OTLP's own spelling.
    @Test func theOtlpRecordCarriesTheEvent() throws {
        let e = Event(event: "look", traceID: String(repeating: "ab", count: 16), service: "eyes",
                      startedAt: Date(timeIntervalSince1970: 2), durationMs: 1.5, outcome: "error", error: "blind",
                      counts: ["reads": 3], facts: ["source": "tree"])
        let body = try JSONSerialization.jsonObject(with: Edge.otlp(e)) as! [String: Any]
        let resource = (body["resourceLogs"] as! [[String: Any]])[0]
        let record = ((resource["scopeLogs"] as! [[String: Any]])[0]["logRecords"] as! [[String: Any]])[0]
        #expect(record["timeUnixNano"] as? String == "2000000000" && record["traceId"] as? String == e.traceID)
        let attributes = Dictionary(uniqueKeysWithValues: (record["attributes"] as! [[String: Any]])
            .map { ($0["key"] as! String, ($0["value"] as! [String: Any]).first!.value as! AnyHashable) })
        #expect(attributes == ["event": "look", "outcome": "error", "duration_ms": 1.5, "error": "blind",
                               "counts.reads": "3", "source": "tree"])
    }

    /// Lines sent at once land whole, one per event, and the outbox sends them all before
    /// it says it is drained.
    @Test func eventsSentAtOnceLandWhole() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "eyes-\(UUID())/events.jsonl")
        let outbox = Outbox(Edge(collector: nil, file: file))
        let e = await event()
        for _ in 0..<200 { outbox.add(e) }
        await outbox.drained()
        let written = try lines(file)
        #expect(written.count == 200)
        #expect(written.allSatisfy { $0["trace_id"] as? String == e.traceID })
    }
}

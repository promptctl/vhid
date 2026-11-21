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
        #expect(events[0].attributes == ["who": "me"] && events[0].counts == ["seen": 0])
        #expect(events[1].outcome == "error" && events[1].error == "Refusal()")
        #expect(events.allSatisfy { $0.traceID.count == 32 && $0.durationMs >= 0 })
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

    /// Lines sent at once land whole, one per event, and the outbox sends them all before
    /// it says it is drained.
    @Test func eventsSentAtOnceLandWhole() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "eyes-\(UUID())/events.jsonl")
        let outbox = Outbox(Edge(service: "eyes", collector: nil, file: file, deliver: { _ in }))
        let e = await event()
        for _ in 0..<200 { outbox.add(e.record) }
        await outbox.drained()
        let written = try lines(file)
        #expect(written.count == 200)
        #expect(written.allSatisfy { $0["trace_id"] as? String == e.traceID })
    }

    /// A unit inside a bound trace - a vhid call's - carries it.
    @Test func aUnitJoinsTheTraceItRunsIn() async {
        let collected = Collected(), trace = Telemetry.newTrace()
        await Telemetry.$export.withValue(collected.export) {
            await Telemetry.$trace.withValue(trace) { await Telemetry.unit("e") {} }
        }
        #expect(collected.all.map(\.traceID) == [trace])
    }

    /// `TRACEPARENT` as the W3C trace context spells it, and nothing else: an invalid one
    /// starts a new trace, as the recommendation says a receiver must.
    @Test func aTraceparentIsReadAsTheW3CSpellsIt() {
        let trace = "4bf92f3577b34da6a3ce929d0e0e4736"
        #expect(Telemetry.traceID(in: "00-\(trace)-00f067aa0ba902b7-01") == trace)
        for invalid in ["", "01-\(trace)-00f067aa0ba902b7-01", "00-\(trace.uppercased())-00f067aa0ba902b7-01",
                        "00-\(String(repeating: "0", count: 32))-00f067aa0ba902b7-01", "00-\(trace)-0000000000000000-01",
                        "00-\(trace)-00f067aa0ba902b7", "00-\(trace)-00f067aa0ba902b7-01-extra"] {
            #expect(Telemetry.traceID(in: invalid) == nil, "\(invalid)")
        }
    }

    /// A child is started naming the trace underway, which it reads back as its own.
    @Test func aChildIsStartedInTheTraceUnderway() async {
        let trace = Telemetry.newTrace()
        let environment = Telemetry.$trace.withValue(trace) { Telemetry.childEnvironment }
        #expect(environment["TRACEPARENT"].flatMap(Telemetry.traceID(in:)) == trace)
    }
}

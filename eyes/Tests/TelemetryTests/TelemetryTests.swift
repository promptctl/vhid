import Foundation
import Synchronization
@testable import Telemetry
import TelemetryTesting
import Testing

@Suite struct TelemetryTests {
    struct Refusal: Error {}

    /// A wrapper that names its cause, as the device runs' stops do.
    struct Wrapped: Caused { let cause: any Error }

    /// A unit records once however it ends, with what was noted and counted inside it, and
    /// what a returned value found as its result.
    @Test func aUnitRecordsOnceHoweverItEnds() async throws {
        let collected = Collected()
        await Telemetry.$export.withValue(collected.export) {
            _ = await Telemetry.unit("ok", result: { $0 ? "yes" : "no" }) {
                Telemetry.note(.app, "me"); Telemetry.count(.pages, 0); return true
            }
            await #expect(throws: Refusal.self) { try await Telemetry.unit("fails") { throw Refusal() } }
        }
        let records = collected.all
        #expect(records.map(\.event) == ["ok", "fails"])
        #expect(records[0].outcome == .ok && records[0].error == nil)
        #expect(records[0].attributes == ["app": "me", "result": "yes"] && records[0].counts == ["pages": 0])
        #expect(records[1].outcome == .failed && records[1].error == "Refusal()")
        #expect(records.allSatisfy { $0.traceID.count == 32 && $0.spanID.count == 16 && $0.duration >= .zero })
        #expect(records[0].traceID != records[1].traceID)
    }

    /// A unit inside another is a child of its span, on its trace; a fresh one starts its own.
    @Test func aUnitInsideAnotherIsAChildOfItsSpan() async {
        let collected = Collected()
        await Telemetry.$export.withValue(collected.export) {
            await Telemetry.unit("outer") {
                await Telemetry.unit("inner") {}
                await Telemetry.unit("call", trace: .fresh) {}
            }
        }
        let byName = Dictionary(uniqueKeysWithValues: collected.all.map { ($0.event, $0) })
        let outer = byName["outer"]!, inner = byName["inner"]!, call = byName["call"]!
        #expect(inner.traceID == outer.traceID && inner.parentSpanID == outer.spanID)
        #expect(call.traceID != outer.traceID && call.parentSpanID == nil)
    }

    /// A child process is handed the unit underway as its parent, in the W3C header the
    /// first unit in a process reads; a header that is not one is no parent.
    @Test func aChildIsHandedTheUnitUnderwayAsItsParent() async throws {
        let collected = Collected()
        let header = await Telemetry.$export.withValue(collected.export) {
            await Telemetry.unit("parent") { Telemetry.childEnvironment([:])["TRACEPARENT"] }
        }
        let parent = collected.all[0]
        #expect(header == "00-\(parent.traceID)-\(parent.spanID)-01")
        let read = try #require(Telemetry.traceparent(header))
        #expect(read.trace == parent.traceID && read.span == parent.spanID)
        #expect(Telemetry.childEnvironment(["TRACEPARENT": "stale"])["TRACEPARENT"] == nil)
        for bad in ["", "00-abc-def-01", "ff-\(parent.traceID)-\(parent.spanID)-01",
                    "00-\(String(repeating: "0", count: 32))-\(parent.spanID)-01", "00-\(parent.traceID.uppercased())-\(parent.spanID)-01"] {
            #expect(Telemetry.traceparent(bad) == nil, "\(bad)")
        }
    }

    /// Words come from the dispatcher; a unit that withholds them names the kinds of its causes.
    @Test func aUnitThatWithholdsItsWordsNamesTheKindsOfItsCauses() async {
        let collected = Collected()
        await Telemetry.$export.withValue(collected.export) {
            _ = try? await Telemetry.unit("told", said: { _ in "what the caller was told" }) { throw Refusal() }
            _ = try? await Telemetry.unit("silent", said: { _ in "" }) { throw Refusal() }
            _ = try? await Telemetry.unit("typed") {
                Telemetry.withholdErrorWords()
                throw Wrapped(cause: Refusal())
            }
        }
        #expect(collected.all.map(\.error) == ["what the caller was told", nil, "Wrapped: Refusal"])
    }

    /// A unit withdrawn by cancellation says so, through any wrapper, and a tally says how
    /// far it got; one that failed as a cancel landed failed.
    @Test func aCancelledUnitSaysSoAndHowFarItGot() async {
        let collected = Collected()
        let started = AsyncStream<Void>.makeStream()
        let unit = Task {
            await Telemetry.$export.withValue(collected.export) {
                try? await Telemetry.unit("withdrawn") {
                    Telemetry.tally(.reads); Telemetry.tally(.reads)
                    started.continuation.finish()
                    do { try await Task.sleep(for: .seconds(3600)) } catch { throw Wrapped(cause: error) }
                }
                try? await Telemetry.unit("refused") { throw Refusal() }
            }
        }
        for await _ in started.stream {}
        unit.cancel()
        await unit.value
        #expect(collected.all.map(\.outcome) == [.cancelled, .failed])
        #expect(collected.all[0].counts == ["reads": 2])
    }

    // MARK: the edge

    private static func record() -> Record {
        Record(event: "scroll", service: "vhid", traceID: "4bf92f3577b34da6a3ce929d0e0e4736", spanID: "00f067aa0ba902b7",
               parentSpanID: nil, startedAt: Date(timeIntervalSince1970: 1_791_000_000.5), duration: .milliseconds(12),
               outcome: .ok, error: nil, counts: ["scroll_notches_vertical": 3], attributes: ["double_click_ms": .double(500)])
    }

    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "telemetry-tests-\(UUID().uuidString)/events.jsonl")
    }

    private static func edge(_ collector: Edge.Collector?, at file: URL = scratch(),
                             deliver: @escaping @Sendable (URLRequest) async throws -> Void = { _ in Issue.record("nothing was to be sent") }) -> Edge {
        Edge(collector: collector, file: file, deliver: deliver)
    }

    private static func written(_ edge: Edge) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: edge.file.path) else { return [] }
        return try String(contentsOf: edge.file, encoding: .utf8).split(separator: "\n")
            .map { try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    }

    private static func only(_ edge: Edge) throws -> [String: Any] {
        let written = try written(edge)
        try #require(written.count == 1, "\(written)")
        return written[0]
    }

    /// A file an earlier version made readable to all is its owner's alone once it is
    /// appended to.
    @Test func aFileReadableByAllIsMadeTheOwnersAloneWhenAppendedTo() async throws {
        let edge = Self.edge(nil)
        try FileManager.default.createDirectory(at: edge.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: edge.file.path, contents: Data(), attributes: [.posixPermissions: 0o644]))
        await edge.send(Self.record())
        #expect(try FileManager.default.attributesOfItem(atPath: edge.file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func withNoCollectorTheRecordGoesToTheFileReadableByItsOwnerAlone() async throws {
        let edge = Self.edge(nil)
        #expect(await edge.send(Self.record()) == .file)
        #expect(try FileManager.default.attributesOfItem(atPath: edge.file.path)[.posixPermissions] as? Int == 0o600)
        let written = try Self.only(edge)
        #expect(written["sink"] as? String == "file")
        #expect(written["sink_error"] == nil)
        #expect(written["trace_id"] as? String == "4bf92f3577b34da6a3ce929d0e0e4736")
        #expect(written["span_id"] as? String == "00f067aa0ba902b7")
        #expect(written["parent_span_id"] == nil)
        #expect(written["started_at"] as? String == "2026-10-03T04:00:00.500Z")
        #expect(written["duration_ms"] as? Double == 12)
        #expect(written["service"] as? String == "vhid")
    }

    /// Nothing listens on port 1, so the collector's failure is the machine's own refusal.
    @Test func aCollectorThatCannotBeReachedLeavesTheRecordInTheFileSayingWhy() async throws {
        let edge = Self.edge(.init(endpoint: .base("http://127.0.0.1:1")), deliver: Edge.post)
        await edge.send(Self.record())
        let written = try Self.only(edge)
        #expect(written["sink"] as? String == "file")
        #expect((written["sink_error"] as? String)?.hasPrefix("http://127.0.0.1:1/v1/logs: ") == true)
    }

    @Test func aCollectorThatIsNotAUrlLeavesTheRecordInTheFileSayingWhy() async throws {
        let edge = Self.edge(.init(endpoint: .base("collector:4318")), deliver: Edge.post)
        await edge.send(Self.record())
        #expect(try Self.only(edge)["sink_error"] as? String == "OTEL_EXPORTER_OTLP_ENDPOINT is not an http or https URL")
    }

    /// A delivered record is an OTLP logs export in its trace and span, whose attributes are
    /// the record's fields, and the file is not written.
    @Test func aCollectorThatTakesTheRecordIsSentItAsOtlpLogs() async throws {
        let sent = Mutex<[URLRequest]>([])
        let edge = Self.edge(.init(endpoint: .base("http://collector:4318/"), headers: "authorization=Bearer%20x, tenant = vhid"),
                             deliver: { request in sent.withLock { $0.append(request) } })
        #expect(await edge.send(Self.record()) == .otlp)
        #expect(try Self.written(edge).isEmpty)
        let request = try #require(sent.withLock { $0.first })
        #expect(request.url?.absoluteString == "http://collector:4318/v1/logs")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer x")
        #expect(request.value(forHTTPHeaderField: "tenant") == "vhid")
        let payload = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let resource = try #require((body["resourceLogs"] as? [[String: Any]])?.first)
        let log = try #require(((resource["scopeLogs"] as? [[String: Any]])?.first?["logRecords"] as? [[String: Any]])?.first)
        #expect(log["traceId"] as? String == "4bf92f3577b34da6a3ce929d0e0e4736")
        #expect(log["spanId"] as? String == "00f067aa0ba902b7")
        #expect(log["eventName"] as? String == "scroll")
        let attributes = try #require(log["attributes"] as? [[String: Any]])
        func value(_ key: String) -> [String: Any]? { attributes.first { $0["key"] as? String == key }?["value"] as? [String: Any] }
        #expect(value("sink")?["stringValue"] as? String == "otlp")
        #expect(value("outcome")?["stringValue"] as? String == "ok")
        let counts = try #require((value("counts")?["kvlistValue"] as? [String: Any])?["values"] as? [[String: Any]])
        #expect(counts.first?["key"] as? String == "scroll_notches_vertical")
        #expect((counts.first?["value"] as? [String: Any])?["intValue"] as? String == "3")
    }

    @Test func theLogsVariablesWinOverTheGeneralOnesAndAnEmptyOneIsUnset() throws {
        #expect(Edge.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": ""]).collector == nil)
        #expect(Edge.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_EXPORTER_OTLP_HEADERS": "a=1"]).collector
            == .init(endpoint: .base("http://c:4318"), headers: "a=1"))
        #expect(Edge.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_SDK_DISABLED": "TRUE"]).collector == nil)
        #expect(Edge.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_LOGS_EXPORTER": "none"]).collector == nil)
        let logs = try #require(Edge.configured([
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://l:4318/logs",
            "OTEL_EXPORTER_OTLP_HEADERS": "a=1", "OTEL_EXPORTER_OTLP_LOGS_HEADERS": "b=2",
        ]).collector)
        #expect(logs == .init(endpoint: .logs("http://l:4318/logs"), headers: "b=2"))
        #expect(try logs.url.absoluteString == "http://l:4318/logs")
        // A scheme is case-insensitive (RFC 3986).
        #expect(try Edge.Collector(endpoint: .base("HTTPS://c:4318")).url.absoluteString == "HTTPS://c:4318/v1/logs")
        #expect(Edge.configured([:]).file.path.hasSuffix("Library/Logs/\(Telemetry.service)/events.jsonl"))
    }

    @Test func headersThatAreNotKeyValuePairsLeaveTheRecordInTheFileSayingWhy() async throws {
        let edge = Self.edge(.init(endpoint: .base("http://c:4318"), headers: "a=1,=token"))
        await edge.send(Self.record())
        #expect(try Self.only(edge)["sink_error"] as? String == "OTLP header 2 is not a key=value pair with its value percent-encoded")
    }

    /// Only `http/json` is spoken, named or unset; any other protocol is refused on the
    /// record before anything is sent.
    @Test(arguments: ["grpc", "http/protobuf"])
    func anotherProtocolIsRefusedOnTheRecordBeforeAnythingIsSent(_ named: String) async throws {
        let collector = try #require(Edge.Collector(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4317", "OTEL_EXPORTER_OTLP_PROTOCOL": named]))
        let edge = Self.edge(collector)
        await edge.send(Self.record())
        #expect(try Self.only(edge)["sink_error"] as? String == "OTEL_EXPORTER_OTLP_PROTOCOL is \(named), and only http/json is sent")
        let json = try #require(Edge.Collector(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_EXPORTER_OTLP_PROTOCOL": "http/json"]))
        #expect(try json.url.absoluteString == "http://c:4318/v1/logs")
    }

    /// Nothing listens on port 1; the refusal names the collector without its password.
    @Test func aCollectorsPasswordIsNotWrittenWithItsRefusal() async throws {
        let edge = Self.edge(.init(endpoint: .base("http://user:apikey@127.0.0.1:1")), deliver: Edge.post)
        await edge.send(Self.record())
        #expect(try String(contentsOf: edge.file, encoding: .utf8).contains("apikey") == false)
        #expect((try Self.only(edge)["sink_error"] as? String)?.hasPrefix("http://127.0.0.1:1/v1/logs: ") == true)
    }

    // MARK: the outbox

    /// The cancellation that ended a unit does not reach the delivery of its record.
    @Test func aCancelledUnitsRecordIsStillDelivered() async throws {
        let delivered = Mutex<[Bool]>([])
        let outbox = Outbox(Self.edge(.init(endpoint: .base("http://c:4318")), deliver: { _ in delivered.withLock { $0.append(Task.isCancelled) } }))
        let run = Task {
            try await Telemetry.$export.withValue({ outbox.add($0) }) {
                try await Telemetry.unit("scroll") {
                    withUnsafeCurrentTask { $0?.cancel() }
                    try Task.checkCancellation()
                }
            }
        }
        _ = await run.result
        await outbox.drained()
        #expect(delivered.withLock { $0 } == [false])
    }

    /// Lines sent at once land whole, one per record, and the outbox sends them all before
    /// it says it is drained.
    @Test func recordsSentAtOnceLandWhole() async throws {
        let edge = Self.edge(nil)
        let outbox = Outbox(edge)
        for _ in 0..<200 { outbox.add(Self.record()) }
        await outbox.drained()
        let written = try Self.written(edge)
        #expect(written.count == 200)
        #expect(written.allSatisfy { $0["trace_id"] as? String == Self.record().traceID })
    }
}

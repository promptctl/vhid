import Foundation
import Synchronization
@testable import Telemetry
import Testing

/// The one edge every record leaves the process by: the file, the collector, and the OTLP
/// environment read by one rule. [LAW:behavior-not-structure]
struct EdgeTests {
    private static func scratch(collector: Edge.Collector? = nil,
                                deliver: @escaping @Sendable (URLRequest) async throws -> Void = { _ in Issue.record("nothing was to be sent") }) -> Edge {
        Edge(service: "vhid", collector: collector,
             file: FileManager.default.temporaryDirectory.appending(path: "telemetry-tests-\(UUID().uuidString)/events.jsonl"), deliver: deliver)
    }

    private static func written(_ edge: Edge) throws -> [[String: Any]] {
        guard FileManager.default.fileExists(atPath: edge.file.path) else { return [] }
        return try String(contentsOf: edge.file, encoding: .utf8).split(separator: "\n").map {
            try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    private static func only(_ edge: Edge) throws -> [String: Any] {
        let written = try written(edge)
        try #require(written.count == 1, "\(written)")
        return written[0]
    }

    private static let record = Record(event: "scroll", traceID: "4bf92f3577b34da6a3ce929d0e0e4736",
                                       startedAt: Date(timeIntervalSince1970: 1_791_000_000.5),
                                       fields: ["duration_ms": .double(12), "outcome": .string("ok"),
                                                "counts": .object(["scroll_notches_vertical": .int(3)])])

    @Test func withNoCollectorTheRecordGoesToTheFile() async throws {
        let edge = Self.scratch()
        await edge.send(Self.record)
        #expect(try FileManager.default.attributesOfItem(atPath: edge.file.path)[.posixPermissions] as? Int == 0o600)
        let written = try Self.only(edge)
        #expect(written["sink"] as? String == "file")
        #expect(written["sink_error"] == nil)
        #expect(written["event"] as? String == "scroll")
        #expect(written["trace_id"] as? String == "4bf92f3577b34da6a3ce929d0e0e4736")
        #expect(written["started_at"] as? String == "2026-10-03T04:00:00.500Z")
        #expect(written["duration_ms"] as? Double == 12)
        #expect(written["service"] as? String == "vhid")
    }

    /// An eyes unit's event lands in the fields a vhid invocation's record has, so one sink
    /// holds one schema.
    @Test func anEventIsSentInTheFieldsAnInvocationHas() async throws {
        let edge = Self.scratch()
        await edge.send(Event(event: "look", traceID: String(repeating: "ab", count: 16), startedAt: Date(timeIntervalSince1970: 2),
                              durationMs: 1.5, outcome: "error", error: "blind", counts: ["reads": 3], attributes: ["source": "tree"]).record)
        let written = try Self.only(edge)
        #expect(written["counts"] as? [String: Int] == ["reads": 3])
        #expect(written["attributes"] as? [String: String] == ["source": "tree"])
        #expect(written["outcome"] as? String == "error" && written["error"] as? String == "blind")
        #expect(written["service"] as? String == "vhid")
    }

    /// Nothing listens on port 1, so the collector's failure is the machine's own refusal.
    @Test func aCollectorThatCannotBeReachedLeavesTheRecordInTheFileSayingWhy() async throws {
        let edge = Self.scratch(collector: .init(endpoint: .base("http://127.0.0.1:1")), deliver: Edge.post)
        await edge.send(Self.record)
        let written = try Self.only(edge)
        #expect(written["sink"] as? String == "file")
        #expect((written["sink_error"] as? String)?.hasPrefix("http://127.0.0.1:1/v1/logs: ") == true)
    }

    @Test func aCollectorThatIsNotAUrlLeavesTheRecordInTheFileSayingWhy() async throws {
        let edge = Self.scratch(collector: .init(endpoint: .base("collector:4318")), deliver: Edge.post)
        await edge.send(Self.record)
        #expect(try Self.only(edge)["sink_error"] as? String == "OTEL_EXPORTER_OTLP_ENDPOINT is not an http or https URL")
    }

    /// A delivered record is an OTLP logs export whose attributes are the record's fields,
    /// and the file is not written.
    @Test func aCollectorThatTakesTheRecordIsSentItAsOtlpLogs() async throws {
        let sent = Mutex<[URLRequest]>([])
        let edge = Self.scratch(collector: .init(endpoint: .base("http://collector:4318/"), headers: "authorization=Bearer%20x, tenant = vhid"),
                                deliver: { request in sent.withLock { $0.append(request) } })
        await edge.send(Self.record)
        #expect(try Self.written(edge).isEmpty)
        let request = try #require(sent.withLock { $0.first })
        #expect(request.url?.absoluteString == "http://collector:4318/v1/logs")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer x")
        #expect(request.value(forHTTPHeaderField: "tenant") == "vhid")
        let payload = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let resource = try #require((body["resourceLogs"] as? [[String: Any]])?.first)
        let service = ((resource["resource"] as? [String: Any])?["attributes"] as? [[String: Any]])?.first
        #expect((service?["value"] as? [String: Any])?["stringValue"] as? String == "vhid")
        let log = try #require(((resource["scopeLogs"] as? [[String: Any]])?.first?["logRecords"] as? [[String: Any]])?.first)
        #expect(log["traceId"] as? String == "4bf92f3577b34da6a3ce929d0e0e4736")
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
        func configured(_ environment: [String: String]) -> Edge.Collector? { Edge.configured(service: "vhid", environment).collector }
        #expect(configured(["OTEL_EXPORTER_OTLP_ENDPOINT": ""]) == nil)
        #expect(configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_EXPORTER_OTLP_HEADERS": "a=1"])
            == .init(endpoint: .base("http://c:4318"), headers: "a=1"))
        #expect(configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_SDK_DISABLED": "TRUE"]) == nil)
        #expect(configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_LOGS_EXPORTER": "none"]) == nil)
        let logs = try #require(configured([
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://l:4318/logs",
            "OTEL_EXPORTER_OTLP_HEADERS": "a=1", "OTEL_EXPORTER_OTLP_LOGS_HEADERS": "b=2",
        ]))
        #expect(logs == .init(endpoint: .logs("http://l:4318/logs"), headers: "b=2"))
        #expect(try logs.url.absoluteString == "http://l:4318/logs")
    }

    /// The file is named for the service, so `vhid` and `eyes` each keep their own log.
    @Test func theFileIsNamedForTheService() {
        #expect(Edge.configured(service: "eyes", [:]).file.path.hasSuffix("Library/Logs/eyes/events.jsonl"))
    }

    @Test func headersThatAreNotKeyValuePairsLeaveTheRecordInTheFileSayingWhy() async throws {
        let edge = Self.scratch(collector: .init(endpoint: .base("http://c:4318"), headers: "a=1,oops"))
        await edge.send(Self.record)
        #expect(try Self.only(edge)["sink_error"] as? String == "OTLP header 2 is not a key=value pair with its value percent-encoded")
    }

    @Test func aGrpcCollectorIsRefusedOnTheRecordBeforeAnythingIsSent() async throws {
        let collector = try #require(Edge.Collector(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4317", "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc"]))
        let edge = Self.scratch(collector: collector)
        await edge.send(Self.record)
        #expect(try Self.only(edge)["sink_error"] as? String == "OTEL_EXPORTER_OTLP_PROTOCOL is grpc, and this sends OTLP/HTTP JSON")
    }

    /// Nothing listens on port 1; the refusal names the collector without its password.
    @Test func aCollectorsPasswordIsNotWrittenWithItsRefusal() async throws {
        let edge = Self.scratch(collector: .init(endpoint: .base("http://user:apikey@127.0.0.1:1")), deliver: Edge.post)
        await edge.send(Self.record)
        #expect(try String(contentsOf: edge.file, encoding: .utf8).contains("apikey") == false)
        #expect((try Self.only(edge)["sink_error"] as? String)?.hasPrefix("http://127.0.0.1:1/v1/logs: ") == true)
    }
}

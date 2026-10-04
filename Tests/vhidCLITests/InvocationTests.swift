import Foundation
@testable import Helper
import Input
import Installations
import Synchronization
import TestClock
import Testing
@testable import vhid

/// Every invocation leaves one record, however it ends, and the record carries what the
/// verb decided. Driven through `Devices.using` over a real XPC connection to a far end of
/// the test's own, because that is where the reports are counted. [LAW:behavior-not-structure]
@Suite struct InvocationTests {
    static let at = ScreenPoint(x: 40, y: 30)!

    /// `body` against a far end that acknowledges every act until `after` of them.
    private static func against<T: Sendable>(acknowledging after: Int = .max, _ body: (Devices) async throws -> T) async throws -> T {
        let service = UnreachableTests.Service(.refusing(after: after, refusal: UnreachableTests.devicesDown))
        let listener = NSXPCListener.anonymous()
        listener.delegate = service
        listener.resume()
        defer { listener.invalidate() }
        let helper = HelperConnection(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), service: UnreachableTests.far, replyTimeout: .seconds(20))
        return try await Devices.using(helper, body)
    }

    private static func scroll(vertical: Int, horizontal: Int, clock: ManualClock = ManualClock(), on devices: Devices) async throws -> String {
        try await ScrollCommand.scroll(at: at, vertical: vertical, horizontal: horizontal, holding: .none,
                                       with: Pointer(mouse: devices.mouse, cursor: { at }), devices.keyboard, clock: clock)
    }

    private static func only(_ export: EventExport) throws -> [String: Any] {
        let written = try export.written
        try #require(written.count == 1, "\(written)")
        return written[0]
    }

    /// A scroll of nothing reached the devices and sent nothing, and says so in zeros;
    /// no invocation at all writes nothing.
    @Test func aVerbThatDidNothingIsRecordedAsZerosAndNoInvocationIsNotRecorded() async throws {
        let export = EventExport.scratch()
        #expect(try export.written.isEmpty)
        _ = try await Invocation.record("scroll", via: .commandLine, to: export) { _ in
            try await Self.against { try await Self.scroll(vertical: 0, horizontal: 0, on: $0) }
        }
        let record = try Self.only(export)
        #expect(record["event"] as? String == "scroll")
        #expect(record["entry"] as? String == "cli")
        #expect(record["outcome"] as? String == "ok")
        #expect(record["error"] == nil)
        #expect(record["counts"] as? [String: Int] == [
            "keyboard_reports": 0, "mouse_reports": 0, "scroll_notches_vertical": 0, "scroll_notches_horizontal": 0,
        ])
    }

    @Test func aScrollRecordsItsNotchesOnEachAxisAndTheRestBetweenThem() async throws {
        let export = EventExport.scratch()
        _ = try await Invocation.record("scroll", via: .mcp, to: export) { _ in
            try await Self.against { try await Self.scroll(vertical: -3, horizontal: 2, on: $0) }
        }
        let record = try Self.only(export)
        let counts = try #require(record["counts"] as? [String: Int])
        #expect(counts["scroll_notches_vertical"] == 3)
        #expect(counts["scroll_notches_horizontal"] == 2)
        #expect(counts["mouse_reports"] == 3)
        #expect(record["attributes"] as? [String: Int] == ["notch_rest_ms": 200])
    }

    /// The cancel lands inside the second rest, from the task the roll runs in, so the roll
    /// stops before its third notch and the record says how far it got.
    @Test func aScrollCancelledPartWayIsRecordedAsCancelledWithTheNotchesItSent() async throws {
        let export = EventExport.scratch(), clock = ManualClock()
        clock.cancel(afterSleeps: 2) { withUnsafeCurrentTask { $0?.cancel() } }
        let roll = Task {
            try await Invocation.record("scroll", via: .mcp, to: export) { _ in
                try await Self.against { try await Self.scroll(vertical: 10, horizontal: 0, clock: clock, on: $0) }
            }
        }
        let stopped = await #expect(throws: (any Error).self) { try await roll.value }
        #expect(stopped?.causes.contains { $0 is CancellationError } == true)
        let record = try Self.only(export)
        #expect(record["outcome"] as? String == "cancelled")
        #expect(record["error"] as? String == "the run was cancelled")
        #expect((record["counts"] as? [String: Int])?["scroll_notches_vertical"] == 2)
    }

    /// The error on the record is the sentence the caller was given.
    @Test func aFailedVerbIsRecordedWithWhatItsCallerWasTold() async throws {
        let export = EventExport.scratch()
        let thrown = await #expect(throws: (any Error).self) {
            try await Invocation.record("scroll", via: .mcp, to: export) { _ in
                try await Self.against(acknowledging: 1) { try await Self.scroll(vertical: 5, horizontal: 0, on: $0) }
            }
        }
        let record = try Self.only(export)
        #expect(record["outcome"] as? String == "failed")
        #expect(record["error"] as? String == thrown.map(Invocation.Entry.mcp.told))
        #expect((record["counts"] as? [String: Int])?["scroll_notches_vertical"] == 1)
    }

    /// A tool call is one invocation, named after its tool. The tool is a stub, so this
    /// checks the dispatcher and nothing a verb does.
    @Test func anMcpToolCallIsRecordedUnderItsToolsName() async throws {
        let export = EventExport.scratch()
        let click = VerbTool(Help.click, []) { _, _ in "clicked" }
        let stdio = Stdio(), transport = AnsweringTransport(stdio)
        stdio.call(1, then: [.end])
        let server = await McpCommand.server([click], on: Installation(service: "ai.promptctl.vhid.tests.nobody")!, over: transport, recordingTo: export)
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
        let record = try Self.only(export)
        #expect(record["event"] as? String == "click")
        #expect(record["entry"] as? String == "mcp")
        #expect(record["outcome"] as? String == "ok")
    }

    /// The command line and MCP name a verb the same way, so one verb's records are found
    /// under one name.
    @Test func aCommandIsNamedAsItIsTypedAndAsItsToolIs() {
        #expect(Vhid.name(of: Vhid.self) == "vhid")
        #expect(Vhid.name(of: DriverCommand.State.self) == "driver state")
        let commands = Vhid.configuration.subcommands.map { Vhid.name(of: $0) }
        for tool in Tools.all.map(\.tool.name) {
            #expect(commands.contains(tool), "no command is named \(tool)")
        }
    }

    // MARK: the export edge

    private static func record(_ outcome: Outcome = .ok) -> InvocationRecord {
        InvocationRecord(event: "scroll", entry: .commandLine, traceID: "4bf92f3577b34da6a3ce929d0e0e4736",
                         startedAt: Date(timeIntervalSince1970: 1_791_000_000.5), duration: .milliseconds(12),
                         outcome: outcome, error: nil, counts: [.verticalNotches: 3], attributes: [.notchRestMilliseconds: .int(200)])
    }

    @Test func withNoCollectorTheRecordGoesToTheFile() async throws {
        let export = EventExport.scratch()
        await export.export(Self.record())
        let written = try Self.only(export)
        #expect(written["sink"] as? String == "file")
        #expect(written["sink_error"] == nil)
        #expect(written["trace_id"] as? String == "4bf92f3577b34da6a3ce929d0e0e4736")
        #expect(written["started_at"] as? String == "2026-10-03T04:00:00.500Z")
        #expect(written["duration_ms"] as? Double == 12)
        #expect(written["service"] as? String == "vhid")
    }

    /// Nothing listens on port 1, so the collector's failure is the machine's own refusal.
    @Test func aCollectorThatCannotBeReachedLeavesTheRecordInTheFileSayingWhy() async throws {
        let scratch = EventExport.scratch()
        let export = EventExport(collector: "http://127.0.0.1:1", file: scratch.file, deliver: EventExport.post)
        await export.export(Self.record())
        let written = try Self.only(export)
        #expect(written["sink"] as? String == "file")
        #expect((written["sink_error"] as? String)?.hasPrefix("http://127.0.0.1:1/v1/logs: ") == true)
    }

    @Test func aCollectorThatIsNotAUrlLeavesTheRecordInTheFileSayingWhy() async throws {
        let scratch = EventExport.scratch()
        let export = EventExport(collector: "collector:4318", file: scratch.file, deliver: EventExport.post)
        await export.export(Self.record())
        #expect(try Self.only(export)["sink_error"] as? String == #"OTEL_EXPORTER_OTLP_ENDPOINT "collector:4318" is not an http or https URL"#)
    }

    /// A delivered record is an OTLP logs export whose attributes are the record's fields,
    /// and the file is not written.
    @Test func aCollectorThatTakesTheRecordIsSentItAsOtlpLogs() async throws {
        let sent = Mutex<[URLRequest]>([])
        let scratch = EventExport.scratch()
        let export = EventExport(collector: "http://collector:4318/", file: scratch.file, deliver: { request in sent.withLock { $0.append(request) } })
        await export.export(Self.record())
        #expect(try export.written.isEmpty)
        let request = try #require(sent.withLock { $0.first })
        #expect(request.url?.absoluteString == "http://collector:4318/v1/logs")
        #expect(request.httpMethod == "POST")
        let payload = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let resource = try #require((body["resourceLogs"] as? [[String: Any]])?.first)
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

    @Test func anEmptyEndpointIsNoCollector() {
        #expect(EventExport.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": ""]).collector == nil)
        #expect(EventExport.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318"]).collector == "http://c:4318")
    }
}

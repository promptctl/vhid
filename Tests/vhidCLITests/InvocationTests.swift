import ArgumentParser
import DriverExtension
import Foundation
@testable import Helper
import Input
import Installations
import Signals
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
        try await ScrollCommand.scroll(at: .point(at), vertical: vertical, horizontal: horizontal, holding: .none,
                                       with: Pointer(mouse: devices.mouse, cursor: { at }, displays: { .vast }, clock: clock, randomness: RandomSource(seed: 1), hand: .macOSDefault, traced: Invocation.traced), devices.keyboard)
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
        _ = try await Invocation.record("scroll", via: .commandLine, to: export.export) { _ in
            try await Self.against { try await Self.scroll(vertical: 0, horizontal: 0, on: $0) }
        }
        let record = try Self.only(export)
        #expect(record["event"] as? String == "scroll")
        #expect(record["entry"] as? String == "cli")
        #expect(record["outcome"] as? String == "ok")
        #expect(record["error"] == nil)
        #expect(record["counts"] as? [String: Int] == [
            "keyboard_reports": 0, "mouse_reports": 0, "scroll_notches_vertical": 0, "scroll_notches_horizontal": 0,
            "key_rollovers": 0, "key_hesitations": 0,
        ])
    }

    @Test func aScrollRecordsItsNotchesOnEachAxisAndTheRestBetweenThem() async throws {
        let export = EventExport.scratch()
        _ = try await Invocation.record("scroll", via: .mcp, to: export.export) { _ in
            try await Self.against { try await Self.scroll(vertical: -3, horizontal: 2, on: $0) }
        }
        let record = try Self.only(export)
        let counts = try #require(record["counts"] as? [String: Int])
        #expect(counts["scroll_notches_vertical"] == 3)
        #expect(counts["scroll_notches_horizontal"] == 2)
        #expect(counts["mouse_reports"] == 3)
        let attributes = try #require(record["attributes"] as? [String: Any])
        // The rest on the point, then a pause after each notch, totalled by kind.
        let pauses = try #require(attributes["pauses"] as? [String: [String: Any]])
        #expect(Set(pauses.keys) == ["rest", "notch"])
        #expect(pauses["rest"]?["count"] as? Int == 1)
        #expect(pauses["notch"]?["count"] as? Int == 3)
        #expect((pauses["notch"]?["ms"] as? Double).map { (600 ... 900).contains($0) } == true)
        #expect(attributes["double_click_ms"] is Double)
        #expect(attributes["key_repeat_delay_ms"] is Double)
        #expect(attributes["seed"] is String)
        // The pointer was already on its point, so the move there drew a path of no length.
        let paths = try #require(attributes["paths"] as? [[String: Any]])
        try #require(paths.count == 1)
        #expect(paths[0].compactMapValues { $0 as? Double } == ["fitts_width": 20, "planned_ms": 0, "bow_kept": 1, "steered_reports": 0, "closing_reports": 0, "lost_reports": 0])
        // A point is aimed at exactly, and the cursor read back there when it landed.
        #expect(paths[0]["aimed"] as? [Double] == [40, 30])
        #expect(paths[0]["landed"] as? [Double] == [40, 30])
        #expect(paths[0]["box"] == nil)
        // Which of the four structures the move drew, by its design-note name.
        #expect(Set(["direct", "undershoot", "overshoot", "two_corrections"]).contains(paths[0]["structure"] as? String ?? ""))
        // The layout the path was kept on, as the pointer read it.
        #expect(paths[0]["displays"] as? [[Double]] == [[-100_000, -100_000, 200_000, 200_000]])
    }

    /// Typing records its waits beside the pointer's, totalled by the report each ends in,
    /// and a report for every change of the keys held.
    @Test func typingRecordsItsWaitsByTheReportEachEndsIn() async throws {
        let export = EventExport.scratch()
        _ = try await Invocation.record("type", via: .mcp, to: export.export) { _ in
            try await Self.against { devices in
                try await TypeCommand.type("Ab", on: VerbTests.us, into: .anywhere,
                                           with: Typist(keyboard: devices.keyboard, clock: ManualClock(), randomness: RandomSource(seed: 1), traced: Invocation.typed),
                                           front: { nil })
            }
        }
        let record = try Self.only(export)
        #expect((record["counts"] as? [String: Int])?["keyboard_reports"] == 6)
        let pauses = try #require((record["attributes"] as? [String: Any])?["pauses"] as? [String: [String: Any]])
        #expect(pauses.mapValues { $0["count"] as? Int } == ["modifier_down": 1, "key_down": 2, "key_up": 2, "modifier_up": 1])
        #expect((pauses["key_up"]?["ms"] as? Double).map { (80 ... 400).contains($0) } == true)
        // Every report went out on time on a fake clock, and the record says so.
        #expect((record["attributes"] as? [String: Any])?["keys_late_ms"] as? Double == 0)
        #expect((record["counts"] as? [String: Int])?["key_rollovers"] == 0)
        #expect((record["attributes"] as? [String: Any])?["key_hesitation_ms"] as? Double == 0)
    }

    /// Prose rolls over and hesitates, and its record says how often: the rollovers counted,
    /// the hesitations counted and their drawn lengths totalled, and every character's
    /// key-down ending a `key_down` wait, hesitation or none.
    @Test func typingRecordsItsRolloversAndHesitations() async throws {
        let text = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 4)
        let export = EventExport.scratch()
        _ = try await Invocation.record("type", via: .mcp, to: export.export) { _ in
            try await Self.against { devices in
                try await TypeCommand.type(text, on: VerbTests.us, into: .anywhere,
                                           with: Typist(keyboard: devices.keyboard, clock: ManualClock(), randomness: RandomSource(seed: 1), traced: Invocation.typed),
                                           front: { nil })
            }
        }
        let record = try Self.only(export)
        #expect(((record["counts"] as? [String: Int])?["key_rollovers"] ?? 0) > 0)
        #expect(((record["counts"] as? [String: Int])?["key_hesitations"] ?? 0) > 0)
        let attributes = try #require(record["attributes"] as? [String: Any])
        // Each hesitation is 150 ms or more.
        #expect((attributes["key_hesitation_ms"] as? Double).map { $0 >= 150 } == true)
        let pauses = try #require(attributes["pauses"] as? [String: [String: Any]])
        #expect(pauses["key_down"]?["count"] as? Int == text.count)
    }

    /// A move the cursor never follows throws, and its record still carries the move: the box
    /// it was given and the point drawn inside it, every steered report given up on, and the
    /// closing loop's reports up to the stall that stopped it, and no landing. The error
    /// names the box too. Through the pointer `Devices` opens, which is where moves are recorded.
    @Test func aMoveThatWouldNotReachIsRecordedWithItsPath() async throws {
        let export = EventExport.scratch()
        let thrown = await #expect(throws: (any Error).self) {
            try await Invocation.record("move", via: .mcp, to: export.export) { _ in
                // The far end's cursor is always at (0, 0).
                try await Self.against { try await MoveCommand.move(to: .box(ScreenRect(x: 30, y: -5, width: 20, height: 10)!), with: $0.pointer) }
            }
        }
        #expect(thrown.map { "\($0)".contains("drawn inside the box 30,-5,20,10") } == true, "\(String(describing: thrown))")
        let record = try Self.only(export)
        #expect(record["outcome"] as? String == "failed")
        let recorded = try #require((record["attributes"] as? [String: Any])?["paths"] as? [[String: Any]])
        try #require(recorded.count == 1)
        // The layout as the daemon answered it, which the path was kept on.
        #expect(recorded[0]["displays"] as? [[Double]] == [[0, 0, 1920, 1080]])
        let paths = recorded.map { $0.compactMapValues { $0 as? Double } }
        #expect(paths[0]["planned_ms"].map { $0 > 0 } == true)
        #expect(paths[0]["bow_kept"].map { (0 ... 1).contains($0) } == true)
        #expect(paths[0]["steered_reports"].map { $0 > 0 } == true)
        #expect(paths[0]["lost_reports"] == paths[0]["steered_reports"])
        #expect(paths[0]["closing_reports"] == Double(Pointer.stalls))
        #expect(paths[0]["fitts_width"] == 10)
        #expect(recorded[0]["box"] as? [Double] == [30, -5, 20, 10])
        #expect(Set(["direct", "undershoot", "overshoot", "two_corrections"]).contains(recorded[0]["structure"] as? String ?? ""))
        let aimed = try #require(recorded[0]["aimed"] as? [Double])
        #expect((32 ... 48).contains(aimed[0]) && (-3 ... 3).contains(aimed[1]), "\(aimed)")
        #expect(recorded[0]["landed"] == nil)
    }

    /// The cancel lands inside the pause after the second notch, from the task the roll runs
    /// in, so the roll stops before its third notch and the record says how far it got,
    /// the pause it stopped in included.
    @Test func aScrollCancelledPartWayIsRecordedAsCancelledWithTheNotchesItSent() async throws {
        let export = EventExport.scratch(), clock = ManualClock()
        clock.cancel(afterSleeps: 3) { withUnsafeCurrentTask { $0?.cancel() } }
        let roll = Task {
            try await Invocation.record("scroll", via: .mcp, to: export.export) { _ in
                try await Self.against { try await Self.scroll(vertical: 10, horizontal: 0, clock: clock, on: $0) }
            }
        }
        let stopped = await #expect(throws: (any Error).self) { try await roll.value }
        #expect(stopped?.causes.contains { $0 is CancellationError } == true)
        let record = try Self.only(export)
        #expect(record["outcome"] as? String == "cancelled")
        #expect(record["error"] as? String == "the run was cancelled")
        #expect((record["counts"] as? [String: Int])?["scroll_notches_vertical"] == 2)
        let pauses = try #require((record["attributes"] as? [String: Any])?["pauses"] as? [String: [String: Any]])
        #expect(pauses["rest"]?["count"] as? Int == 1)
        #expect(pauses["notch"]?["count"] as? Int == 2)
    }

    /// The error on the record is the sentence the caller was given.
    @Test func aFailedVerbIsRecordedWithWhatItsCallerWasTold() async throws {
        let export = EventExport.scratch()
        let thrown = await #expect(throws: (any Error).self) {
            try await Invocation.record("scroll", via: .mcp, to: export.export) { _ in
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
        try await Self.serve([click], to: export)
        let record = try Self.only(export)
        #expect(record["event"] as? String == "click")
        #expect(record["entry"] as? String == "mcp")
        #expect(record["outcome"] as? String == "ok")
        #expect((record["attributes"] as? [String: Double])?["queued_ms"] != nil)
    }

    /// One call to `click` against `tools`, served the way `vhid mcp` serves it: the
    /// session ends when stdin does, and the process when everything under way has landed.
    private static func serve(_ tools: [VerbTool], to export: EventExport) async throws {
        let stdio = Stdio(), transport = AnsweringTransport(stdio), flights = Flights()
        stdio.call(1, then: [.end])
        let server = await McpCommand.server(tools, on: .nobody, over: transport, recordingTo: export, carriedBy: flights)
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
        await flights.landed()
    }

    /// A call naming no tool is refused as a protocol error, and recorded like any call -
    /// under the method, since a made-up name is not a verb.
    @Test func anMcpCallNamingNoToolIsRecordedAsFailed() async throws {
        let export = EventExport.scratch()
        try await Self.serve([], to: export)
        let record = try Self.only(export)
        #expect(record["event"] as? String == "tools/call")
        #expect(record["outcome"] as? String == "failed")
        #expect((record["error"] as? String)?.contains("there is no tool called") == true)
    }

    /// The answer goes out before the record does, and the record still lands before the
    /// server's process would exit.
    @Test func anMcpCallIsAnsweredWithoutWaitingOnItsRecord() async throws {
        let answered = Mutex(false), sawAnswer = Mutex<Bool?>(nil)
        let scratch = EventExport.scratch()
        let slow = EventExport(collector: .init(endpoint: .base("http://c:4318")), file: scratch.file, deliver: { _ in
            while !answered.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
            sawAnswer.withLock { $0 = true }
        })
        let click = VerbTool(Help.click, []) { _, _ in "clicked" }
        let stdio = Stdio(), transport = AnsweringTransport(stdio), flights = Flights()
        stdio.call(1, then: [])
        let server = await McpCommand.server([click], on: .nobody, over: transport, recordingTo: slow, carriedBy: flights)
        try await server.start(transport: transport)
        while stdio.sent.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        answered.withLock { $0 = true }
        stdio.feed([.end])
        await server.waitUntilCompleted()
        await flights.landed()
        #expect(sawAnswer.withLock { $0 } == true)
    }

    /// Says what `UntypeableCharacters` says, with a character of a password in it.
    private struct QuotesTheText: Error, CustomStringConvertible {
        var description: String { "U.S. has no keys for €" }
    }

    /// `type`'s errors can quote the text it was given, so its record names their kinds.
    @Test func aVerbThatTypesTextIsRecordedWithItsErrorsKindsNotTheirWords() async throws {
        let export = EventExport.scratch()
        _ = try? await Invocation.record("type", via: .mcp, to: export.export) { _ in
            Invocation.typesText()
            throw QuotesTheText()
        }
        #expect(try String(contentsOf: export.file, encoding: .utf8).contains("€") == false)
        #expect(try Self.only(export)["error"] as? String == "QuotesTheText")
    }

    @Test func refusedToolArgumentsAreRecordedWithoutBeingQuoted() async throws {
        let export = EventExport.scratch()
        _ = try? await Invocation.record("type", via: .mcp, to: export.export) { _ in throw ArgumentRefused("text 123456 is not a string") }
        #expect(try Self.only(export)["error"] as? String == Invocation.Entry.refusedArguments)
    }

    /// A cancel that lands while a verb fails for its own reason does not hide the reason.
    @Test func aVerbThatFailedAsACancelLandedIsRecordedAsFailed() async throws {
        let export = EventExport.scratch()
        let run = Task {
            try await Invocation.record("click", via: .mcp, to: export.export) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw UnreachableTests.devicesDown
            }
        }
        _ = await run.result
        #expect(try Self.only(export)["outcome"] as? String == "failed")
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
                         outcome: outcome, error: nil, counts: [.verticalNotches: 3], attributes: [.doubleClickMilliseconds: .double(500)])
    }

    @Test func withNoCollectorTheRecordGoesToTheFile() async throws {
        let export = EventExport.scratch()
        await export.export(Self.record())
        #expect(try FileManager.default.attributesOfItem(atPath: export.file.path)[.posixPermissions] as? Int == 0o600)
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
        let export = EventExport(collector: .init(endpoint: .base("http://127.0.0.1:1")), file: scratch.file, deliver: EventExport.post)
        await export.export(Self.record())
        let written = try Self.only(export)
        #expect(written["sink"] as? String == "file")
        #expect((written["sink_error"] as? String)?.hasPrefix("http://127.0.0.1:1/v1/logs: ") == true)
    }

    @Test func aCollectorThatIsNotAUrlLeavesTheRecordInTheFileSayingWhy() async throws {
        let scratch = EventExport.scratch()
        let export = EventExport(collector: .init(endpoint: .base("collector:4318")), file: scratch.file, deliver: EventExport.post)
        await export.export(Self.record())
        #expect(try Self.only(export)["sink_error"] as? String == "OTEL_EXPORTER_OTLP_ENDPOINT is not an http or https URL")
    }

    /// A delivered record is an OTLP logs export whose attributes are the record's fields,
    /// and the file is not written.
    @Test func aCollectorThatTakesTheRecordIsSentItAsOtlpLogs() async throws {
        let sent = Mutex<[URLRequest]>([])
        let scratch = EventExport.scratch()
        let export = EventExport(collector: .init(endpoint: .base("http://collector:4318/"), headers: "authorization=Bearer%20x, tenant = vhid"),
                                 file: scratch.file, deliver: { request in sent.withLock { $0.append(request) } })
        await export.export(Self.record())
        #expect(try export.written.isEmpty)
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
        #expect(EventExport.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": ""]).collector == nil)
        #expect(EventExport.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_EXPORTER_OTLP_HEADERS": "a=1"]).collector
            == .init(endpoint: .base("http://c:4318"), headers: "a=1"))
        #expect(EventExport.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_SDK_DISABLED": "TRUE"]).collector == nil)
        #expect(EventExport.configured(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_LOGS_EXPORTER": "none"]).collector == nil)
        let logs = try #require(EventExport.configured([
            "OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4318", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "http://l:4318/logs",
            "OTEL_EXPORTER_OTLP_HEADERS": "a=1", "OTEL_EXPORTER_OTLP_LOGS_HEADERS": "b=2",
        ]).collector)
        #expect(logs == .init(endpoint: .logs("http://l:4318/logs"), headers: "b=2"))
        #expect(try logs.url.absoluteString == "http://l:4318/logs")
    }

    @Test func headersThatAreNotKeyValuePairsLeaveTheRecordInTheFileSayingWhy() async throws {
        let scratch = EventExport.scratch()
        let export = EventExport(collector: .init(endpoint: .base("http://c:4318"), headers: "a=1,oops"), file: scratch.file,
                                 deliver: { _ in Issue.record("a request with unreadable headers was sent") })
        await export.export(Self.record())
        #expect(try Self.only(export)["sink_error"] as? String == "OTLP header 2 is not a key=value pair with its value percent-encoded")
    }

    @Test func aGrpcCollectorIsRefusedOnTheRecordBeforeAnythingIsSent() async throws {
        let scratch = EventExport.scratch()
        let collector = try #require(EventExport.Collector(["OTEL_EXPORTER_OTLP_ENDPOINT": "http://c:4317", "OTEL_EXPORTER_OTLP_PROTOCOL": "grpc"]))
        let export = EventExport(collector: collector, file: scratch.file, deliver: { _ in Issue.record("JSON was sent to a gRPC collector") })
        await export.export(Self.record())
        #expect(try Self.only(export)["sink_error"] as? String == "OTEL_EXPORTER_OTLP_PROTOCOL is grpc, and vhid sends OTLP/HTTP JSON")
    }

    /// Nothing listens on port 1; the refusal names the collector without its password.
    @Test func aCollectorsPasswordIsNotWrittenWithItsRefusal() async throws {
        let scratch = EventExport.scratch()
        let export = EventExport(collector: .init(endpoint: .base("http://user:apikey@127.0.0.1:1")), file: scratch.file, deliver: EventExport.post)
        await export.export(Self.record())
        #expect(try String(contentsOf: export.file, encoding: .utf8).contains("apikey") == false)
        #expect((try Self.only(export)["sink_error"] as? String)?.hasPrefix("http://127.0.0.1:1/v1/logs: ") == true)
    }

    /// The cancellation that ended the verb does not reach the delivery of its record.
    @Test func aCancelledInvocationsRecordIsStillDeliveredToTheCollector() async throws {
        let delivered = Mutex<[Bool]>([])
        let scratch = EventExport.scratch()
        let export = EventExport(collector: .init(endpoint: .base("http://c:4318")), file: scratch.file,
                                 deliver: { _ in delivered.withLock { $0.append(Task.isCancelled) } })
        let run = Task {
            try await Invocation.record("scroll", via: .mcp, to: export.export) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }
        }
        _ = await run.result
        #expect(delivered.withLock { $0 } == [false])
        #expect(try export.written.isEmpty)
    }

    // MARK: the command line's dispatcher

    /// `arguments` run as `Vhid.main` runs argv. Whatever the run threw is the record's to say.
    private static func commandLine(_ arguments: [String], to export: EventExport) async {
        _ = try? await Invocation.record(Vhid._commandName, via: .commandLine, to: export.export) { try await Vhid.run(arguments, in: $0) }
    }

    /// ArgumentParser answers `--help` with a `help` command it never declares among
    /// `vhid`'s subcommands.
    @Test func askingForHelpIsRecordedAsHelp() async throws {
        for arguments in [["--help"], ["scroll", "--help"], ["help", "click"]] {
            let export = EventExport.scratch()
            await Self.commandLine(arguments, to: export)
            let record = try Self.only(export)
            #expect(record["event"] as? String == "help", "\(arguments)")
            #expect(record["outcome"] as? String == "ok", "\(arguments)")
        }
    }

    /// The refusal quotes the argument back to the operator, and the record does not:
    /// this one was meant for a password field.
    @Test func refusedArgumentsAreRecordedUnderTheRootWithoutBeingQuoted() async throws {
        let export = EventExport.scratch()
        await Self.commandLine(["type", "a", "hunter2"], to: export)
        #expect(try String(contentsOf: export.file, encoding: .utf8).contains("hunter2") == false)
        let refused = try Self.only(export)
        #expect(refused["error"] as? String == Invocation.Entry.refusedArguments)
    }

    @Test func anArgumentThatCannotBeParsedIsRecordedUnderTheRoot() async throws {
        let export = EventExport.scratch()
        await Self.commandLine(["clik"], to: export)
        let record = try Self.only(export)
        #expect(record["event"] as? String == "vhid")
        #expect(record["outcome"] as? String == "failed")
        #expect((record["error"] as? String)?.isEmpty == false)
    }

    /// A session stopped from outside - Control-C or SIGTERM, which cancel the task serving
    /// it - withdraws the call it is running, whose record says it was cancelled and what
    /// it had sent, and ends once that record is out.
    @Test func aSessionStoppedFromOutsideRecordsItsRunningCallAsCancelled() async throws {
        let (began, begin) = AsyncStream<Void>.makeStream()
        let waiting = VerbTool(Help.click, []) { _, _ in
            Invocation.count(.mouseReports)
            begin.yield()
            try await Task.sleep(for: .seconds(3600))
            return "clicked"
        }
        let export = EventExport.scratch(), stdio = Stdio(), signals = FirstSignal()
        let session = Task {
            try await McpCommand.serve([waiting], on: Installation(service: "ai.promptctl.vhid.tests.nobody")!,
                                       over: AnsweringTransport(stdio), recordingTo: export, stoppedBy: signals)
        }
        stdio.call(4, then: [])
        for await _ in began { break }
        // As the command line's watch does: the signal is taken, then the session cancelled.
        _ = signals.take(SIGTERM)
        session.cancel()
        let ended = await withTaskGroup(of: Result<Void, any Error>?.self) { race in
            race.addTask { await session.result }
            race.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            defer { race.cancelAll() }
            return await race.next() ?? nil
        }
        let ending = try #require(ended, "the session is still serving after its task was cancelled")
        #expect(throws: CancellationError.self) { try ending.get() }
        let record = try Self.only(export)
        #expect(record["event"] as? String == "click")
        #expect(record["outcome"] as? String == "cancelled")
        #expect((record["counts"] as? [String: Int])?["mouse_reports"] == 1)
        #expect((record["attributes"] as? [String: Any])?["signal"] as? String == "SIGTERM")
    }

    /// The command line's dispatcher, as a shell meets it: `vhid mcp` serving, then a
    /// signal. Its record is written as cancelled, it says so, and it then dies by that
    /// signal, which is what tells a shell it was stopped.
    @Test(arguments: [SIGINT, SIGTERM])
    func aVerbStoppedByASignalIsRecordedAsCancelledAndDiesByIt(_ number: Int32) async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "vhid-tests-\(UUID().uuidString)")
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = Bundle(for: Kept.self).bundleURL.deletingLastPathComponent().appending(path: "vhid")
        process.arguments = ["mcp"]
        // The record goes to this home's Library/Logs/vhid, and to no collector.
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("OTEL_") }
            .merging(["CFFIXED_USER_HOME": home.path]) { $1 }
        let stderr = Pipe()
        (process.standardInput, process.standardOutput, process.standardError) = (stdin, stdout, stderr)
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: home)
        }
        // A server that never answers is ended, which ends the read below at end of file.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(10))
            process.terminate()
        }
        defer { watchdog.cancel() }
        // Answered, so the dispatcher is past setting up its watch.
        stdin.fileHandleForWriting.write(Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"1"}}}"# + "\n").utf8))
        var answered = ""
        while !answered.contains("\n") {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            answered += String(decoding: chunk, as: UTF8.self)
        }
        try #require(answered.contains(#""id":1"#), "vhid mcp never answered initialize: \(answered)")
        watchdog.cancel()
        kill(process.processIdentifier, number)
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == number)
        let said = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(said.hasSuffix("vhid: the run was cancelled\n"), "\(said)")
        let written = try String(contentsOf: home.appending(path: "Library/Logs/vhid/events.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        try #require(written.count == 1, "\(written)")
        #expect(written[0]?["event"] as? String == "mcp")
        #expect(written[0]?["outcome"] as? String == "cancelled")
        #expect(written[0]?["error"] as? String == "the run was cancelled")
        #expect((written[0]?["attributes"] as? [String: Any])?["signal"] as? String == (number == SIGINT ? "SIGINT" : "SIGTERM"))
    }

    /// A verb that reads the machine - `doctor`, `driver`, `service standing` - is stopped
    /// as every verb is: the cancel a signal makes ends the command its reading is
    /// running, the child with it, and the record says cancelled, at once rather than at
    /// the command's limit, and names the command it ended.
    @Test(.timeLimit(.minutes(1))) func aReadingCancelledMidCommandIsRecordedAsCancelledAndLeavesNoChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "vhid-reading-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let export = EventExport.scratch()
        let verb = Task {
            try await Invocation.record("driver state", via: .commandLine, to: export.export) { _ in
                try await reading { stop in
                    Result { try Command("/bin/sh", "-c", "echo $$ > \(pidFile.path); exec sleep 600").run(by: .within(.seconds(30), or: stop)) }
                }
            }
        }
        func pid() -> pid_t? { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
        while pid() == nil { try await Task.sleep(for: .milliseconds(10)) }
        verb.cancel()
        await #expect(throws: CancellationError.self) { try await verb.value }
        let record = try Self.only(export)
        #expect(record["event"] as? String == "driver state")
        #expect(record["outcome"] as? String == "cancelled")
        #expect(try #require(record["duration_ms"] as? Double) < 10_000)
        let stopped = try #require((record["attributes"] as? [String: Any])?["stopped"] as? [String])
        #expect(stopped == ["sh -c echo $$ > \(pidFile.path); exec sleep 600"])
        let child = try #require(pid())
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    /// `doctor` prints its own report and exits 1 with nothing more to say.
    @Test func aVerbThatExitsNonzeroSayingNothingMoreIsRecordedWithNoError() async throws {
        let export = EventExport.scratch()
        _ = try? await Invocation.record("doctor", via: .commandLine, to: export.export) { _ in throw ExitCode.failure }
        let record = try Self.only(export)
        #expect(record["outcome"] as? String == "failed")
        #expect(record["error"] == nil)
    }
}

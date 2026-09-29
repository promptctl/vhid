import Foundation
import Synchronization

/// One unit of work's record: everything known about it, emitted once, when it ends.
/// [LAW:nothing-unseen] The field names are the default set every codebase starts from;
/// eyes adds `facts`, and renames none of them.
public struct Event: Sendable, Equatable, Encodable {
    public let event: String
    public let traceID: String
    public let service: String
    public let startedAt: Date
    public let durationMs: Double
    public let outcome: String
    /// Absent when the unit ended well.
    public let error: String?
    /// Every count the unit keeps, zeros included: a zero is a fact, not a gap.
    public let counts: [String: Int]
    /// What else the unit said about itself: which reader, shared or taken.
    public let facts: [String: String]

    enum CodingKeys: String, CodingKey {
        case event, service, outcome, error, counts, facts
        case traceID = "trace_id", startedAt = "started_at", durationMs = "duration_ms"
    }
}

/// An event as it left the process, carrying where it went.
///
/// [LAW:types-are-the-program] `sinkError` is present only when the collector was
/// configured and could not take the event; a file record with no collector configured was
/// never a failure, so the count of undelivered events is the count of records carrying it.
public struct Exported: Sendable, Equatable, Encodable {
    public enum Sink: String, Sendable, Encodable { case otlp, file }

    public let event: Event
    public let sink: Sink
    public let sinkError: String?

    enum CodingKeys: String, CodingKey { case sink, sinkError = "sink_error" }

    public func encode(to encoder: any Encoder) throws {
        try event.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sink, forKey: .sink)
        try c.encodeIfPresent(sinkError, forKey: .sinkError)
    }
}

public enum Telemetry {
    public typealias Export = @Sendable (Event) async -> Void

    /// Where every event goes. The process's outbox by default; a test binds a collector.
    @TaskLocal public static var export: Export = { Outbox.standard.add($0) }

    /// Waits for every event still on its way out. The process calls it once, before it
    /// exits, so an event in flight is not lost with the process. [LAW:no-silent-failure]
    public static func drained() async { await Outbox.standard.drained() }

    /// The unit underway, which `note` and `count` annotate. A unit started inside another
    /// shares its trace, so a look and the grant readings it waited on read as one.
    @TaskLocal static var current: Recorder?

    /// Runs `work` as one unit of work and emits its event when it ends - returned, thrown
    /// or cancelled alike. `outcome` names how a returned value ended. [LAW:nothing-unseen]
    public static func unit<T, Failure: Error>(
        _ name: String, isolation: isolated (any Actor)? = #isolation,
        outcome: (T) -> String = { _ in "ok" }, _ work: () async throws(Failure) -> T
    ) async throws(Failure) -> T {
        let recorder = Recorder(trace: current?.trace ?? Self.newTrace())
        let clock = ContinuousClock(), start = clock.now, startedAt = Date()
        func emit(_ outcome: String, _ error: String?) async {
            let (counts, facts) = recorder.taken()
            let took = clock.now - start
            let ms = Double(took.components.seconds) * 1000 + Double(took.components.attoseconds) / 1e15
            await export(Event(event: name, traceID: recorder.trace, service: "eyes", startedAt: startedAt,
                               durationMs: ms, outcome: outcome, error: error, counts: counts, facts: facts))
        }
        let ran: Result<T, Failure> = await $current.withValue(recorder) {
            do throws(Failure) { return .success(try await work()) } catch { return .failure(error) }
        }
        switch ran {
        case .success(let value):
            await emit(outcome(value), nil)
            return value
        case .failure(let error):
            await emit(Task.isCancelled ? "cancelled" : "error", "\(error)")
            throw error
        }
    }

    /// Adds a fact to the unit underway; outside one it has nowhere to go and is dropped,
    /// which only a caller with no unit around it can do.
    public static func note(_ key: String, _ value: String) { current?.note(key, value) }

    /// Sets a count on the unit underway.
    public static func count(_ key: String, _ value: Int) { current?.count(key, value) }

    /// Adds to a count on the unit underway, so a unit that ends early still says how far
    /// it got, and a unit that does a thing many times says its total.
    public static func tally(_ key: String, by amount: Int = 1) { current?.tally(key, by: amount) }

    /// A W3C trace id: 16 random bytes, as hex.
    private static func newTrace() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

final class Recorder: Sendable {
    let trace: String
    private let state = Mutex<([String: Int], [String: String])>(([:], [:]))

    init(trace: String) { self.trace = trace }

    func note(_ key: String, _ value: String) { state.withLock { $0.1[key] = value } }
    func count(_ key: String, _ value: Int) { state.withLock { $0.0[key] = value } }
    func tally(_ key: String, by amount: Int) { state.withLock { $0.0[key, default: 0] += amount } }
    func taken() -> ([String: Int], [String: String]) { state.withLock { $0 } }
}

/// Events on their way out of the process, each sent in a task of its own.
///
/// [LAW:nothing-unseen] The hot path never waits on the pipeline: a look or a gate hands its
/// event over and returns, and a collector slow to answer slows no reading. The send is
/// detached, so a unit withdrawn by cancellation still delivers its event, not a refusal.
final class Outbox: Sendable {
    static let standard = Outbox(Edge.standard)

    private let edge: Edge
    private let sending = Mutex<[UUID: Task<Void, Never>]>([:])

    init(_ edge: Edge) { self.edge = edge }

    func add(_ event: Event) {
        let id = UUID()
        // Registered under the lock the task removes itself under, so it cannot leave first.
        sending.withLock {
            $0[id] = Task.detached { [self] in
                await edge.send(event)
                _ = sending.withLock { $0.removeValue(forKey: id) }
            }
        }
    }

    func drained() async {
        while let next = sending.withLock({ $0.values.first }) { await next.value }
    }
}

/// The one place an event leaves the process. [LAW:single-enforcer]
///
/// OTLP to the collector `OTEL_EXPORTER_OTLP_ENDPOINT` names; with none named, or one that
/// cannot take it, a line of JSON appended to `file`. An event is never dropped for want
/// of a collector.
public struct Edge: Sendable {
    public let collector: URL?
    public let file: URL

    public init(collector: URL?, file: URL) {
        self.collector = collector
        self.file = file
    }

    static let standard = Edge(
        collector: ProcessInfo.processInfo.environment["OTEL_EXPORTER_OTLP_ENDPOINT"].flatMap(URL.init(string:)),
        file: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/eyes/events.jsonl"))

    /// Sends one event, and says where it went.
    @discardableResult
    public func send(_ event: Event) async -> Exported {
        if let collector {
            do {
                try await Self.post(event, to: collector)
                return Exported(event: event, sink: .otlp, sinkError: nil)
            } catch {
                return appended(Exported(event: event, sink: .file, sinkError: "\(error)"))
            }
        }
        return appended(Exported(event: event, sink: .file, sinkError: nil))
    }

    /// Appends the record to the file as one write to a descriptor opened for appending, so
    /// lines sent at once, from this process or another, land whole and never over each
    /// other. A file that cannot be written is the last place left to say anything, so it
    /// is said on stderr, which stdout under `eyes mcp` is not.
    private func appended(_ exported: Exported) -> Exported {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .sortedKeys
            let line = try encoder.encode(exported) + [0x0A]
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let fd = open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            let wrote = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard wrote == line.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            FileHandle.standardError.write(Data("eyes: event \(exported.event.event) not recorded at \(file.path): \(error)\n".utf8))
        }
        return exported
    }

    private struct Refused: Error, CustomStringConvertible { let description: String }

    private static func post(_ event: Event, to collector: URL) async throws {
        var request = URLRequest(url: collector.appending(path: "v1/logs"), timeoutInterval: 2)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try otlp(event)
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Refused(description: "\(collector) answered \(status)") }
    }

    /// The event as one OTLP/HTTP JSON log record. [LAW:effects-at-boundaries]
    static func otlp(_ event: Event) throws -> Data {
        func attribute(_ key: String, _ value: String) -> [String: Any] { ["key": key, "value": ["stringValue": value]] }
        func attribute(_ key: String, _ value: Int) -> [String: Any] { ["key": key, "value": ["intValue": "\(value)"]] }
        let attributes: [[String: Any]] = [
            attribute("event", event.event), attribute("outcome", event.outcome),
            ["key": "duration_ms", "value": ["doubleValue": event.durationMs]],
        ] + (event.error.map { [attribute("error", $0)] } ?? [])
            + event.counts.sorted { $0.key < $1.key }.map { attribute("counts.\($0.key)", $0.value) }
            + event.facts.sorted { $0.key < $1.key }.map { attribute($0.key, $0.value) }
        let nanos = UInt64(event.startedAt.timeIntervalSince1970 * 1e9)
        let body: [String: Any] = ["resourceLogs": [[
            "resource": ["attributes": [attribute("service.name", event.service)]],
            "scopeLogs": [["logRecords": [[
                "timeUnixNano": "\(nanos)", "traceId": event.traceID,
                "body": ["stringValue": event.event], "attributes": attributes,
            ]]]],
        ]]]
        return try JSONSerialization.data(withJSONObject: body, options: .sortedKeys)
    }
}

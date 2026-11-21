import Foundation
import Synchronization

/// One unit of work's record as it leaves the process: what every producer renders to and
/// the one `Edge` sends, so a vhid call and the look inside it land in one sink, one schema.
/// [LAW:one-source-of-truth]
public struct Record: Sendable, Equatable {
    public let event: String
    public let traceID: String
    public let startedAt: Date
    /// Everything else the unit says about itself, by field name. The edge adds `event`,
    /// `trace_id`, `service`, `started_at` and where the record went.
    public let fields: [String: JSON]

    public init(event: String, traceID: String, startedAt: Date, fields: [String: JSON]) {
        (self.event, self.traceID, self.startedAt, self.fields) = (event, traceID, startedAt, fields)
    }
}

/// One eyes unit of work's record: everything known about it, emitted once, when it ends.
/// [LAW:nothing-unseen] The field names are the default set every codebase starts from.
public struct Event: Sendable, Equatable {
    public let event: String
    public let traceID: String
    public let startedAt: Date
    public let durationMs: Double
    public let outcome: String
    /// Absent when the unit ended well.
    public let error: String?
    /// Every count the unit keeps, zeros included: a zero is a fact, not a gap.
    public let counts: [String: Int]
    /// What else the unit said about itself: which reader, shared or taken, which app.
    public let attributes: [String: String]

    public init(event: String, traceID: String, startedAt: Date, durationMs: Double, outcome: String, error: String?,
                counts: [String: Int], attributes: [String: String]) {
        (self.event, self.traceID, self.startedAt, self.durationMs) = (event, traceID, startedAt, durationMs)
        (self.outcome, self.error, self.counts, self.attributes) = (outcome, error, counts, attributes)
    }

    /// The event as the edge sends it, in the fields a vhid invocation's record has.
    public var record: Record {
        var fields: [String: JSON] = [
            "duration_ms": .double(durationMs),
            "outcome": .string(outcome),
            "counts": .object(counts.mapValues(JSON.int)),
            "attributes": .object(attributes.mapValues(JSON.string)),
        ]
        fields["error"] = error.map(JSON.string)
        return Record(event: event, traceID: traceID, startedAt: startedAt, fields: fields)
    }
}

public enum Telemetry {
    public typealias Export = @Sendable (Event) async -> Void

    /// Where every event goes. The process's outbox by default; a test binds a collector.
    @TaskLocal public static var export: Export = { send($0.record) }

    /// Hands `record` to the process's outbox, which sends it through the one edge.
    public static func send(_ record: Record) { Outbox.standard.add(record) }

    /// Waits for every record still on its way out. The process calls it once, before it
    /// exits, so a record in flight is not lost with the process. [LAW:no-silent-failure]
    public static func drained() async { await Outbox.standard.drained() }

    /// The trace the running work belongs to: the unit's, inside one; a vhid call's, inside
    /// that; and otherwise the one this process was started in, as `TRACEPARENT` names it.
    /// [LAW:one-source-of-truth] The one place a trace is held.
    @TaskLocal public static var trace: String? = inherited

    /// The trace a parent process named in `TRACEPARENT`, the W3C trace context as the
    /// OpenTelemetry environment carrier spells it: `00-<trace id>-<parent id>-<flags>`.
    /// One that does not parse is no trace context at all, as the W3C recommendation says
    /// a receiver must treat it, and a new trace starts.
    public static let inherited: String? = ProcessInfo.processInfo.environment["TRACEPARENT"].flatMap(traceID(in:))

    static func traceID(in traceparent: String) -> String? {
        let parts = traceparent.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let hex = { (s: String, count: Int) in s.count == count && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
        guard parts.count == 4, parts[0] == "00", hex(parts[1], 32), hex(parts[2], 16), hex(parts[3], 2),
              parts[1] != String(repeating: "0", count: 32), parts[2] != String(repeating: "0", count: 16)
        else { return nil }
        return parts[1]
    }

    /// The environment a child process is started with to join the running trace: this
    /// process's, with `TRACEPARENT` naming the trace underway.
    public static var childEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TRACEPARENT"] = trace.map { "00-\($0)-\(randomHex(8))-01" }
        return environment
    }

    /// A W3C trace id: 16 random bytes, as hex.
    public static func newTrace() -> String { randomHex(16) }

    private static func randomHex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// The unit underway, which `note` and `count` annotate.
    @TaskLocal static var current: Recorder?

    /// Runs `work` as one unit of work and emits its event when it ends - returned, thrown
    /// or cancelled alike. `outcome` names how a returned value ended. A unit started
    /// inside another, or inside a vhid call, shares its trace. [LAW:nothing-unseen]
    public static func unit<T, Failure: Error>(
        _ name: String, isolation: isolated (any Actor)? = #isolation,
        outcome: (T) -> String = { _ in "ok" }, _ work: () async throws(Failure) -> T
    ) async throws(Failure) -> T {
        let trace = self.trace ?? newTrace()
        let recorder = Recorder()
        let clock = ContinuousClock(), start = clock.now, startedAt = Date()
        func emit(_ outcome: String, _ error: String?) async {
            let (counts, attributes) = recorder.taken()
            await export(Event(event: name, traceID: trace, startedAt: startedAt, durationMs: (clock.now - start) / .milliseconds(1),
                               outcome: outcome, error: error, counts: counts, attributes: attributes))
        }
        let ran: Result<T, Failure> = await $trace.withValue(trace) {
            await $current.withValue(recorder) {
                do throws(Failure) { return .success(try await work()) } catch { return .failure(error) }
            }
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

    /// Adds an attribute to the unit underway; outside one it has nowhere to go and is
    /// dropped, which only a caller with no unit around it can do.
    public static func note(_ key: String, _ value: String) { current?.note(key, value) }

    /// Sets a count on the unit underway.
    public static func count(_ key: String, _ value: Int) { current?.count(key, value) }

    /// Adds to a count on the unit underway, so a unit that ends early still says how far
    /// it got, and a unit that does a thing many times says its total.
    public static func tally(_ key: String, by amount: Int = 1) { current?.tally(key, by: amount) }
}

final class Recorder: Sendable {
    private let state = Mutex<([String: Int], [String: String])>(([:], [:]))

    func note(_ key: String, _ value: String) { state.withLock { $0.1[key] = value } }
    func count(_ key: String, _ value: Int) { state.withLock { $0.0[key] = value } }
    func tally(_ key: String, by amount: Int) { state.withLock { $0.0[key, default: 0] += amount } }
    func taken() -> ([String: Int], [String: String]) { state.withLock { $0 } }
}

/// Records on their way out of the process, each sent in a task of its own.
///
/// [LAW:nothing-unseen] The hot path never waits on the pipeline: a call, a look or a gate
/// hands its record over and returns, and a collector slow to answer slows none of them.
/// The send is detached, so work withdrawn by cancellation still delivers its record.
/// [LAW:no-ambient-temporal-coupling] The one owner of what is still in flight, which the
/// process drains before it exits.
public final class Outbox: Sendable {
    static let standard = Outbox(Edge.standard)

    private let edge: Edge
    private let sending = Mutex<[UUID: Task<Void, Never>]>([:])

    public init(_ edge: Edge) { self.edge = edge }

    public func add(_ record: Record) {
        let id = UUID()
        // Registered under the lock the task removes itself under, so it cannot leave first.
        sending.withLock {
            $0[id] = Task.detached { [self] in
                await edge.send(record)
                _ = sending.withLock { $0.removeValue(forKey: id) }
            }
        }
    }

    public func drained() async {
        while let next = sending.withLock({ $0.values.first }) { await next.value }
    }
}

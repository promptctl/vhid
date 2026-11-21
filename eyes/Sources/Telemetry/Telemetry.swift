import Foundation
import Synchronization

/// How a unit of work ended: returned, threw, or was withdrawn. What it found - matched,
/// landed, held - is its `result`, an attribute, so every record answers "did it fail?" in
/// these three words whichever half of the binary it came from. [LAW:one-source-of-truth]
extension Telemetry {
    public enum Outcome: String, Sendable {
        case ok, failed, cancelled
    }
}

/// An error that stopped a run because something else failed under it, carrying that
/// failure. Each layer that wraps a cause declares this beside it, so the cause chain -
/// and with it whether a run was cancelled - is read the same way everywhere.
public protocol Caused: Error {
    var cause: any Error { get }
}

public extension Error {
    /// This error and every cause under it, outermost first.
    var causes: [any Error] {
        Array(sequence(first: self as any Error) { ($0 as? any Caused)?.cause })
    }

    /// Whether the run ended because it was cancelled: a cancellation among its causes,
    /// however many layers wrapped it on the way out. What the work threw says how it ended,
    /// not whether a cancel happened to arrive meanwhile: a run refused as the cancel landed
    /// failed. [LAW:single-enforcer] The one cancellation rule, for every record and every
    /// caller that has to tell a withdrawal from a failure.
    var isCancellation: Bool {
        causes.contains { $0 is CancellationError }
    }
}

public extension Error {
    /// What a report calls this failure.
    ///
    /// Every failure here says what it is, except the one the language supplies:
    /// `CancellationError` has no description of its own, so interpolating it prints
    /// `CancellationError()` at the front of a sentence an operator reads. It is the one
    /// stop that is not a failure at all - the caller asked for it - so it is named as the
    /// thing that happened. [LAW:comments-carry-meaning]
    ///
    /// This is the one place that translation happens, so a cancelled typing run, chord,
    /// click and replay all report it the same way. [LAW:one-source-of-truth]
    var reported: String {
        self is CancellationError ? "the run was cancelled" : "\(self)"
    }
}

/// One unit of work's record: everything known about it, made once, when it ends.
/// [LAW:nothing-unseen] [LAW:types-are-the-program]
public struct Record: Sendable, Equatable {
    public let event: String
    public let service: String
    /// W3C trace and span ids: 16 and 8 random bytes, as lowercase hex.
    public let traceID: String
    public let spanID: String
    /// The span of the unit this one ran inside, or of the process that started this one;
    /// absent for a unit that began its trace.
    public let parentSpanID: String?
    public let startedAt: Date
    public let duration: Duration
    public let outcome: Telemetry.Outcome
    /// Absent when the unit ended well, or when what it ended in had no words to record.
    public let error: String?
    /// Every count the unit keeps, zeros included: a zero is a fact, not a gap.
    public let counts: [String: Int]
    public let attributes: [String: JSON]

    /// The record as named fields, the one rendering both the file's line and the
    /// collector's attributes are made from. [LAW:one-source-of-truth]
    public func fields(sink: Sink) -> [String: JSON] {
        var fields: [String: JSON] = [
            "event": .string(event),
            "service": .string(service),
            "trace_id": .string(traceID),
            "span_id": .string(spanID),
            "started_at": .string(startedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))),
            "duration_ms": .double(duration / .milliseconds(1)),
            "outcome": .string(outcome.rawValue),
            "counts": .object(counts.mapValues(JSON.int)),
            "attributes": .object(attributes),
        ]
        fields["parent_span_id"] = parentSpanID.map(JSON.string)
        fields["error"] = error.map(JSON.string)
        switch sink {
        case .otlp: fields["sink"] = "otlp"
        case .file: fields["sink"] = "file"
        case .fileAfter(let failure): (fields["sink"], fields["sink_error"]) = ("file", .string(failure))
        }
        return fields
    }
}

/// Where a record went: to the collector, or to the file - because no collector is
/// configured, or because the one configured could not take it, which the record then
/// says on itself, there being no later moment in a process that records and exits.
public enum Sink: Sendable, Equatable {
    case otlp
    case file
    case fileAfter(collectorFailure: String)
}

/// A JSON value: what a record's attributes are made of.
public enum JSON: Sendable, Equatable, Encodable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case array([JSON])
    case object([String: JSON])

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// One line of JSON, keys sorted.
    public var line: Data {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(self) + Data("\n".utf8)
        }
    }
}

public enum Telemetry {
    public typealias Export = @Sendable (Record) async -> Void

    /// Where every record goes. The process's outbox by default; a test binds a collector.
    /// [LAW:single-enforcer] The one seam between a unit and the edge.
    @TaskLocal public static var export: Export = { Outbox.standard.add($0) }

    /// Waits for every record still on its way out. Each executable's main calls it once,
    /// before it exits, so a record in flight is not lost with the process.
    /// [LAW:no-silent-failure]
    public static func drained() async { await Outbox.standard.drained() }

    /// The unit underway, which the mutators below annotate. Absent outside one: code
    /// called from a test, or from anything that opened no unit, has no record to add to.
    @TaskLocal static var current: Recorder?

    /// Which trace a unit belongs to.
    public enum Trace: Sendable {
        /// The trace of the unit it runs inside, as a child of that unit's span; outside
        /// any, the trace `TRACEPARENT` names, or a trace of its own when none is named.
        case joined
        /// A trace of its own: a call a long-lived server answers is its own piece of work,
        /// not a part of the hours-long session it arrived in.
        case fresh
    }

    /// Runs `work` as one unit of work and records it when it ends - returned, thrown or
    /// cancelled alike. `result` names what a returned value found; `said` gives an error's
    /// words, which the record carries as `error`, empty or nil for none. [LAW:nothing-unseen]
    public static func unit<T, Failure: Error>(
        _ name: String, trace: Trace = .joined, isolation: isolated (any Actor)? = #isolation,
        result: (T) -> String? = { _ in nil }, said: (any Error) -> String? = { "\($0)" },
        _ work: () async throws(Failure) -> T
    ) async throws(Failure) -> T {
        let parent: (trace: String, span: String)? = switch trace {
        case .joined: current.map { ($0.trace, $0.span) } ?? inherited
        case .fresh: nil
        }
        let recorder = Recorder(name, trace: parent?.trace ?? hex(bytes: 16), parent: parent?.span)
        let startedAt = Date(), started = ContinuousClock.now
        let ran: Result<T, Failure> = await $current.withValue(recorder) {
            do throws(Failure) { return .success(try await work()) } catch { return .failure(error) }
        }
        let ending: (Telemetry.Outcome, String?)
        switch ran {
        case .success(let value):
            recorder.note(.result, result(value).map(JSON.string))
            ending = (.ok, nil)
        case .failure(let error):
            ending = (error.isCancellation ? .cancelled : .failed, recorder.words(for: error, said: said))
        }
        await export(recorder.record(startedAt: startedAt, duration: .now - started, outcome: ending.0, error: ending.1))
        return try ran.get()
    }

    /// Names the unit underway, for a dispatcher that learns which verb it runs only once
    /// its arguments are parsed, inside the unit parsing belongs to.
    public static func name(_ name: String) { current?.name(name) }

    /// Sets an attribute on the unit underway; `nil` removes it.
    public static func note(_ key: Attribute, _ value: JSON?) { current?.note(key, value) }

    /// Sets a count on the unit underway.
    public static func count(_ key: Count, _ value: Int) { current?.count(key, value) }

    /// Adds to a count on the unit underway, so a unit that ends early still says how far
    /// it got, and a unit that does a thing many times says its total.
    public static func tally(_ key: Count, by amount: Int = 1) { current?.tally(key, by: amount) }

    /// Says the unit underway handles text it was given, which can be meant for a password
    /// field. Its record then names the kinds of the error it ended in rather than quoting
    /// the words, which can quote the text.
    public static func withholdErrorWords() { current?.withhold() }

    /// `environment` with `TRACEPARENT` naming the unit underway, for a child process whose
    /// own records belong under it. [LAW:one-source-of-truth] The one place the W3C header
    /// is written, as `inherited` is the one place it is read.
    public static func childEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = environment
        environment["TRACEPARENT"] = current.map { "00-\($0.trace)-\($0.span)-01" }
        return environment
    }

    /// The trace and span `TRACEPARENT` names, read once: what every `.joined` unit begun
    /// outside another joins. A header that is not version, 32 and 16 hex digits and flags is no parent.
    static let inherited: (trace: String, span: String)? = traceparent(ProcessInfo.processInfo.environment["TRACEPARENT"])

    static func traceparent(_ header: String?) -> (trace: String, span: String)? {
        let parts = (header ?? "").split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        func isHex(_ s: String, _ count: Int) -> Bool { s.count == count && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
        // An id of all zeros is the header's own word for none.
        func isID(_ s: String, _ count: Int) -> Bool { isHex(s, count) && s.contains { $0 != "0" } }
        guard parts.count == 4, isHex(parts[0], 2), parts[0] != "ff", isID(parts[1], 32), isID(parts[2], 16), isHex(parts[3], 2)
        else { return nil }
        return (parts[1], parts[2])
    }

    /// What a record says in place of refused arguments' words, which quote them back: an
    /// argument can hold text meant for a password field. The caller saw them; the record,
    /// which outlives the terminal and the conversation, says only that they were refused.
    public static let refusedArguments = "the arguments were refused; what they said is not recorded"

    /// The name records from this process are filed under: the executable's own.
    public static let service = ProcessInfo.processInfo.processName

    static func hex(bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }
}

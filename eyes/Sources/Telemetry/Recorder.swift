import Foundation
import Synchronization

/// What one unit has said about itself so far, from whichever task it said it on.
final class Recorder: Sendable {
    let trace: String
    let span = Telemetry.hex(bytes: 8)
    let parent: String?
    private let state: Mutex<State>

    private struct State {
        var name: String
        var counts: [Telemetry.Count: Int] = [:]
        var attributes: [Telemetry.Attribute: JSON] = [:]
        var accumulated: [Telemetry.Attribute: any Accumulated] = [:]
        var withholds = false
    }

    init(_ name: String, trace: String, parent: String?) {
        (self.trace, self.parent) = (trace, parent)
        state = Mutex(State(name: name))
    }

    func name(_ name: String) { state.withLock { $0.name = name } }
    func note(_ key: Telemetry.Attribute, _ value: JSON?) { state.withLock { $0.attributes[key] = value } }
    func count(_ key: Telemetry.Count, _ value: Int) { state.withLock { $0.counts[key] = value } }
    func tally(_ key: Telemetry.Count, by amount: Int) { state.withLock { $0.counts[key, default: 0] += amount } }
    func withhold() { state.withLock { $0.withholds = true } }

    func accumulate<Value: Accumulated>(_ key: Telemetry.Attribute, _ change: (inout Value) -> Void) {
        state.withLock {
            // Taken out while it changes, so the change is made in place, not to a copy.
            var value: Value
            switch $0.accumulated.removeValue(forKey: key) {
            case nil: value = Value()
            case let kept as Value: value = kept
            case let other?: preconditionFailure("\(key.rawValue) is built up as \(type(of: other)), not \(Value.self)")
            }
            change(&value)
            $0.accumulated[key] = value
        }
    }

    /// What the record says of the error the unit ended in: the kinds of its causes, for a
    /// unit that withholds its words, or else what the dispatcher told its caller.
    func words(for error: any Error, said: (any Error) -> String?) -> String? {
        if state.withLock(\.withholds) { return error.causes.map { "\(type(of: $0))" }.joined(separator: ": ") }
        return said(error).flatMap { $0.isEmpty ? nil : $0 }
    }

    func record(startedAt: Date, duration: Duration, outcome: Telemetry.Outcome, error: String?) -> Record {
        state.withLock {
            let attributes = $0.attributes.merging($0.accumulated.mapValues(\.json)) { _, built in built }
            return Record(event: $0.name, service: Telemetry.service, traceID: trace, spanID: span, parentSpanID: parent,
                          startedAt: startedAt, duration: duration, outcome: outcome, error: error,
                          counts: Dictionary(uniqueKeysWithValues: $0.counts.map { ($0.key.rawValue, $0.value) }),
                          attributes: Dictionary(uniqueKeysWithValues: attributes.map { ($0.key.rawValue, $0.value) }))
        }
    }
}

/// Records on their way out of the process, each sent in a task of its own.
///
/// [LAW:nothing-unseen] The hot path never waits on the pipeline: a unit hands its record
/// over and returns, so a collector slow to answer slows no reading and no tool call's
/// answer. The send is detached, so a unit withdrawn by cancellation still delivers its
/// record, which is the one most worth delivering, where URLSession would give it up at once.
public final class Outbox: Sendable {
    /// The process's outbox. [LAW:no-shared-mutable-globals] One per process, owned here:
    /// `Telemetry.export` adds to it and each main drains it, and nothing else touches it.
    static let standard = Outbox(Edge.configured())

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

    /// Returns once every record added before it, and any added while it waited, is sent.
    public func drained() async {
        while let next = sending.withLock({ $0.values.first }) { await next.value }
    }
}

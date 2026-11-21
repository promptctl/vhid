import Foundation
import Synchronization
import Telemetry
import Testing

/// Every record a unit of work made, collected in place of the edge.
public final class Collected: Sendable {
    private let records = Mutex<[Record]>([])
    public init() {}
    public var all: [Record] { records.withLock { $0 } }
    public var export: Telemetry.Export { { record in self.records.withLock { $0.append(record) } } }

    /// Every record as the file's line renders it, parsed back: what a reader of the log
    /// would find.
    public var written: [[String: Any]] {
        get throws {
            try all.map { try JSONSerialization.jsonObject(with: JSON.object($0.fields(sink: .file)).line) as! [String: Any] }
        }
    }
}

/// A suite whose code runs units of work, with their records kept in the test rather than
/// sent through the process's edge to the real log or collector. A test that asserts on
/// its records binds its own `Collected` inside.
public struct EventsKept: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        try await Telemetry.$export.withValue(Collected().export) { try await function() }
    }
}

extension Trait where Self == EventsKept {
    public static var eventsKept: Self { EventsKept() }
}

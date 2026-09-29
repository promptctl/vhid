import Synchronization
import Telemetry
import Testing

/// Every event a unit of work emitted, collected in place of the edge.
public final class Collected: Sendable {
    private let events = Mutex<[Event]>([])
    public init() {}
    public var all: [Event] { events.withLock { $0 } }
    public var export: Telemetry.Export { { event in self.events.withLock { $0.append(event) } } }
}

/// A suite whose code runs units of work, with their events kept in the test rather than
/// sent through the process's edge to the real log or collector. A test that asserts on
/// its events binds its own `Collected` inside.
public struct EventsKept: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await Telemetry.$export.withValue(Collected().export) { try await function() }
    }
}

extension Trait where Self == EventsKept {
    public static var eventsKept: Self { EventsKept() }
}

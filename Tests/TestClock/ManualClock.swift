import Synchronization

/// A clock that moves only when told to, or when something sleeps until later than now.
public final class ManualClock: Clock {
    public struct Instant: InstantProtocol {
        public let offset: Duration
        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    public init() {}

    private let current = Mutex(Instant(offset: .zero))
    private let slept = Mutex(0)
    /// What to do once something has slept here often enough, for a test that needs a
    /// stop to land inside a wait rather than at a report. [LAW:effects-at-boundaries]
    private let aim = Mutex<(after: Int, fire: (@Sendable () -> Void)?)>((.max, nil))

    public var now: Instant { current.withLock { $0 } }
    public var minimumResolution: Duration { .zero }
    /// How many times something has slept on this clock.
    public var sleeps: Int { slept.withLock { $0 } }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let sleeps = slept.withLock { $0 += 1; return $0 }
        current.withLock { $0 = Swift.max($0, deadline) }
        aim.withLock { if sleeps >= $0.after { $0.fire?() } }
    }

    public func cancel(afterSleeps sleeps: Int, _ fire: @escaping @Sendable () -> Void) {
        aim.withLock { $0 = (sleeps, fire) }
    }

    public func advance(by duration: Duration) {
        current.withLock { $0 = $0.advanced(by: duration) }
    }
}

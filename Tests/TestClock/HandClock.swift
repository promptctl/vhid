import Synchronization

/// A clock the test moves by hand, for code that is given its `now` as an instant.
public final class HandClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    public init() {}
    public var now: ContinuousClock.Instant { instant.withLock { $0 } }
    public func advance(_ by: Duration) { instant.withLock { $0 += by } }
}

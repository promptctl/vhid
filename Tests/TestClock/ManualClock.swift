import Synchronization
import Testing
@_spi(TestClock) import Time

/// A clock that moves only when told to, or when something sleeps until later than now.
///
/// A sleep is the program letting time pass, so it moves the clock to where the sleep
/// ends. A blocking wait is the program waiting on something else with time only as its
/// limit, so it moves nothing: it ends when what it waits on comes, or when the test or a
/// sleeper moves the clock past its deadline, which wakes it.
public final class ManualClock: Swift.Clock, Sendable {
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
    /// The blocking waits under way, each by the instant it waits for and what wakes it.
    private let blocked = Monitor<[Int: (until: Instant, wake: @Sendable () -> Void)]>([:])
    private let nextWait = Mutex(0)

    public var now: Instant { current.withLock { $0 } }
    public var minimumResolution: Duration { .zero }
    /// How many times something has slept on this clock.
    public var sleeps: Int { slept.withLock { $0 } }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let sleeps = slept.withLock { $0 += 1; return $0 }
        move { $0 = Swift.max($0, deadline) }
        aim.withLock { if sleeps >= $0.after { $0.fire?() } }
    }

    public func cancel(afterSleeps sleeps: Int, _ fire: @escaping @Sendable () -> Void) {
        aim.withLock { $0 = (sleeps, fire) }
    }

    public func advance(by duration: Duration) {
        move { $0 = $0.advanced(by: duration) }
    }

    /// Waits until at least `count` blocking waits are under way on this clock: a thread
    /// the test cannot see has reached a wait, and moving the clock now ends that wait and
    /// not one before it.
    public func awaitBlocked(_ count: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        blocked.wait("\(count) waits blocked on the test clock", until: { $0.count >= count }, sourceLocation: sourceLocation)
    }

    /// Waits until a blocking wait for `instant` is under way on this clock, for a test that
    /// must tell one wait from another by the instant each waits for.
    public func awaitBlocked(until instant: Instant, sourceLocation: SourceLocation = #_sourceLocation) {
        blocked.wait("a wait for \(instant.offset) blocked on the test clock", until: { $0.values.contains { $0.until == instant } }, sourceLocation: sourceLocation)
    }


    /// Moves the clock and wakes every blocking wait, outside the clock's own lock: a wait
    /// wakes by taking its own lock, whose holder may be reading the time.
    private func move(_ change: (inout Instant) -> Void) {
        current.withLock { change(&$0) }
        blocked.withLock { $0.values.map(\.wake) }.forEach { $0() }
    }

    /// One blocking wait, woken by every move of the clock and otherwise held for at most
    /// `hangGuard` of real time. A wait the guard ends with the clock short of its deadline
    /// is a test that hung: it is recorded as the failure it is, and the clock is moved to
    /// the deadline so the code under test ends as it would at its limit.
    fileprivate func block(until: Instant, _ wake: @escaping @Sendable () -> Void, _ sleep: (Duration) -> Bool) {
        let id = nextWait.withLock { $0 += 1; return $0 }
        blocked.withLock { $0[id] = (until, wake) }
        defer { blocked.withLock { _ = $0.removeValue(forKey: id) } }
        guard now < until else { return }
        guard !sleep(hangGuard), now < until else { return }
        Issue.record("a wait for \(until.offset) on the test clock was still waiting \(hangGuard) later, with the clock at \(now.offset)")
        move { $0 = Swift.max($0, until) }
    }
}

extension Clock {
    /// The process's one clock, on `manual`, for everything under test to be handed: a test
    /// clock erased to the one the code takes, as swift-clocks' `AnyClock(testClock)` is.
    public init(_ manual: ManualClock) {
        self.init(
            now: { Time.Instant(sinceBoot: manual.now.offset) },
            sleep: { try await manual.sleep(until: ManualClock.Instant(offset: $0.sinceBoot), tolerance: nil) },
            block: { until, wake, sleep in manual.block(until: ManualClock.Instant(offset: until.sinceBoot), wake, sleep) }
        )
    }
}

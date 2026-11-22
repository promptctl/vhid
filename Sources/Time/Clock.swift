import Foundation

/// A moment on the machine's uptime clock: how long the Mac has run since it started, not
/// counting its sleep.
///
/// [LAW:one-source-of-truth] `CLOCK_UPTIME_RAW` is the kernel's, and every process on the
/// Mac reads the same one, so an instant made in a client means the same moment in vhidd
/// and crosses the wire as itself, never as a span the trip there would stretch. Not
/// counting sleep, because nothing runs while the Mac sleeps: a limit that counted it
/// would be past on waking for work that had run a moment of it.
public struct Instant: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let sinceBoot: Duration

    public init(sinceBoot: Duration) {
        self.sinceBoot = sinceBoot
    }

    /// The instant as the wire carries it: whole nanoseconds since the Mac started.
    public init(nanoseconds: UInt64) {
        sinceBoot = .nanoseconds(Int64(clamping: nanoseconds))
    }

    public var nanoseconds: UInt64 { UInt64(clamping: sinceBoot.nanoseconds) }

    public static func < (a: Instant, b: Instant) -> Bool { a.sinceBoot < b.sinceBoot }
    public static func + (instant: Instant, span: Duration) -> Instant { Instant(sinceBoot: instant.sinceBoot + span) }
    public static func - (instant: Instant, span: Duration) -> Instant { Instant(sinceBoot: instant.sinceBoot - span) }
    public static func - (later: Instant, earlier: Instant) -> Duration { later.sinceBoot - earlier.sinceBoot }
    public static func += (instant: inout Instant, span: Duration) { instant = instant + span }

    public var description: String { "\(sinceBoot) since boot" }
}

/// What a process measures and waits on time by: what time it is, a sleep until a given
/// instant, and the one shape every blocking wait takes.
///
/// [LAW:one-source-of-truth] A process has one, made in `main` - `suspending`, the real one
/// - or by a test from its one test clock, and handed to every component that measures or
/// waits. None of them makes a `ContinuousClock` or reads a global `now`, so the one test clock
/// reaches every wait in the process, the blocking ones included: a component with a clock
/// of its own would need a fake of its own, and its tests would run in real time.
public struct Clock: Sendable {
    public let now: @Sendable () -> Instant
    private let sleeper: @Sendable (Instant) async throws -> Void
    private let blocker: @Sendable (_ until: Instant, _ wake: @escaping @Sendable () -> Void, _ sleep: (Duration) -> Bool) -> Void

    /// A clock of the three effects, for a test clock to make. [LAW:effects-at-boundaries]
    /// Behind an SPI, so making one is something only a test clock says it does.
    ///
    /// `block` runs one blocking wait toward `until`. It hands `sleep` the real span the
    /// wait may block for, and `sleep` answers whether something woke it before the span ran
    /// out. `wake` ends that wait early, from any thread, however many times it is called.
    @_spi(TestClock)
    public init(
        now: @escaping @Sendable () -> Instant,
        sleep: @escaping @Sendable (Instant) async throws -> Void,
        block: @escaping @Sendable (_ until: Instant, _ wake: @escaping @Sendable () -> Void, _ sleep: (Duration) -> Bool) -> Void
    ) {
        self.now = now
        sleeper = sleep
        blocker = block
    }

    /// The Mac's own uptime clock. A blocking wait blocks until its instant, and nothing
    /// but what it waits on wakes it sooner.
    public static let suspending: Clock = {
        @Sendable func now() -> Instant { Instant(nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
        return Clock(
            now: now,
            sleep: { try await SuspendingClock().sleep(for: $0 - now(), tolerance: .zero) },
            block: { until, _, sleep in _ = sleep(max(.zero, until - now())) }
        )
    }()

    public func sleep(until instant: Instant) async throws {
        try await sleeper(instant)
    }

    /// Blocks the calling thread for `span` of this clock: a pause between attempts,
    /// which a test clock ends when it is moved past its end.
    public func pause(for span: Duration) {
        let condition = NSCondition(), over = Deadline.within(span, on: self)
        condition.lock(); defer { condition.unlock() }
        while over.wait(on: condition) {}
    }

    /// One blocking wait toward `until`, as `init` describes.
    func block(until: Instant, waking wake: @escaping @Sendable () -> Void, _ sleep: (Duration) -> Bool) {
        blocker(until, wake, sleep)
    }
}

import Darwin
import Foundation

/// A clock as offsets from when it was made: what time it is, and a sleep until a given
/// one. A move's deadlines and a typist's keys are offsets from their start, so this is all
/// of a clock a pointer or a typist needs, and it keeps them free of the clock's type.
public struct Timeline: Sendable {
    public let now: @Sendable () -> Duration
    public let sleep: @Sendable (_ until: Duration) async throws -> Void

    public init<C: Clock>(_ clock: C) where C.Duration == Duration {
        let origin = clock.now
        now = { origin.duration(to: clock.now) }
        sleep = { try await clock.sleep(until: origin.advanced(by: $0), tolerance: .zero) }
    }

    /// The clock every caller's limit is counted on, in every process here: it stops while
    /// the Mac sleeps, as a child process and the driver's daemon do, so a limit is never
    /// found spent on waking for work that ran a moment of it.
    ///
    /// A value and not a clock someone keeps: a `Deadline` carries the timeline it was
    /// made on, so two of these in one process are never read against each other.
    public static var suspending: Timeline { Timeline(SuspendingClock()) }

    /// A sleep until `due` that hands `slept` how long it slept once it ends, however it
    /// ends: one a cancel cut short says how long it got. [LAW:single-enforcer] Every wait a
    /// pointer or a typist makes between its reports is one of these, so every one is traced.
    public func pause(until due: Duration, slept: (Duration) -> Void) async throws {
        let began = now()
        defer { slept(max(now() - began, .zero)) }
        try await sleep(due)
    }

    /// The moment `limit` from now: made where a caller asks, and handed to every lock,
    /// queue and wait below, so the limit covers the whole of the caller's wait.
    public func deadline(within limit: Duration) -> Deadline {
        Deadline(timeline: self, at: now() + limit, limit: limit)
    }
}

/// When a caller's wait is to be over, on the timeline it was made on, and the limit it was
/// made from.
///
/// [LAW:types-are-the-program] Made only by `Timeline.deadline(within:)`, at the moment a
/// request enters a process. Everything below that takes a `Deadline` and never a span, so
/// the time spent waiting for a thread, a lock or a turn is time the limit counted: a span
/// passed down is turned into a deadline by whoever reads it, and every wait above that
/// reader goes uncounted.
public struct Deadline: Sendable {
    private let timeline: Timeline
    private let at: Duration
    /// The span this deadline was made from, for the words of a failure that names it.
    public let limit: Duration

    fileprivate init(timeline: Timeline, at: Duration, limit: Duration) {
        self.timeline = timeline
        self.at = at
        self.limit = limit
    }

    /// What is left of it, and never less than none.
    public var left: Duration { max(at - timeline.now(), .zero) }

    public var passed: Bool { timeline.now() >= at }

    /// How long since it was made, on its own clock: what a wait it bounded cost.
    public var spent: Duration { timeline.now() - (at - limit) }

    /// The deadline as a moment on the wall clock, for the system waits that take one:
    /// `NSLock.lock(before:)`, `NSCondition.wait(until:)`.
    public var date: Date { Date(timeIntervalSinceNow: left.seconds) }
}

/// A span in the units each system wait takes. [LAW:single-enforcer] The one place a
/// `Duration`'s components are read for a kernel or Foundation wait, so each is rounded
/// one way.
public extension Duration {
    var seconds: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }

    /// Whole milliseconds, rounded down, as `poll(2)` takes them: clamped, so a span past
    /// what `Int32` holds waits as long as poll can and not a negative, which is forever.
    var wholeMilliseconds: Int32 {
        Int32(clamping: components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }

    var nanoseconds: Int64 {
        components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000
    }

    /// As `kevent(2)` takes a timeout.
    var timespec: Darwin.timespec {
        Darwin.timespec(tv_sec: Int(components.seconds), tv_nsec: Int(components.attoseconds / 1_000_000_000))
    }
}

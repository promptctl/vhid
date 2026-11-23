import Foundation

/// When a request is to be over, and the limit that put it there.
///
/// [LAW:no-ambient-temporal-coupling] Made only where a request enters - a reading, a CLI
/// verb, a client's call to vhidd, a sweep tick, the release a seat's ending owes - and
/// handed to everything below it. A lock, a condition, a poll or a kevent under it takes
/// this and never a span of its own, so the time a request spends waiting for a thread, a
/// lock or a queue is counted against the limit its caller gave, not started afresh after.
public struct Deadline: Sendable, CustomStringConvertible {
    /// What the request was given where it entered.
    public let limit: Duration
    public let at: Instant
    public let clock: Clock

    /// Over `limit` from now.
    public static func within(_ limit: Duration, on clock: Clock) -> Deadline {
        Deadline(limit: limit, at: clock.now() + limit, clock: clock)
    }

    /// Over at `at`, an instant a caller made somewhere else: a client's deadline, as vhidd
    /// receives it. The limit is what was left of it on arrival.
    public static func at(_ at: Instant, on clock: Clock) -> Deadline {
        Deadline(limit: max(.zero, at - clock.now()), at: at, clock: clock)
    }

    /// This deadline, or `limit` from now where that is sooner: for a wait under the request
    /// that has a limit of its own, as a reply has, and is still over when the request is.
    public func capped(_ limit: Duration) -> Deadline {
        let soonest = min(at, clock.now() + limit)
        return Deadline(limit: min(self.limit, soonest - (at - self.limit)), at: soonest, clock: clock)
    }

    /// What is left of the limit, none once it has passed.
    public var remaining: Duration { max(.zero, at - clock.now()) }
    public var expired: Bool { clock.now() >= at }
    /// When the request entered.
    public var entered: Instant { at - limit }
    /// How long since the request entered.
    public var spent: Duration { clock.now() - entered }

    /// Waits on `condition`, which the caller holds locked, until it is signalled or this
    /// passes, and answers whether any of the limit is left. A caller loops on what it is
    /// waiting for and asks this again; a test clock that moves wakes it.
    public func wait(on condition: NSCondition) -> Bool {
        guard !expired else { return false }
        clock.block(until: at, waking: { condition.lock(); condition.broadcast(); condition.unlock() }) { span in
            condition.wait(until: Date(timeIntervalSinceNow: span.seconds))
        }
        return !expired
    }

    /// One system wait toward this deadline - a `kevent`, a `poll`, a semaphore - that
    /// `wake` ends early. `sleep` is handed the real span it may block for, in whichever
    /// unit it takes, and answers whether it was woken before the span ran out.
    public func block(waking wake: @escaping @Sendable () -> Void, _ sleep: (Duration) -> Bool) {
        clock.block(until: at, waking: wake, sleep)
    }

    /// A request refused because its limit had passed before it could start: while it waited
    /// for a lock, a queue or a thread.
    public var exceeded: Exceeded { Exceeded(limit: limit, spent: spent) }

    public var description: String { "\(limit), \(remaining) left" }

    /// The request's limit passed while it waited, and it was let go before it ran anything.
    public struct Exceeded: Error, Hashable, CustomStringConvertible {
        public let limit: Duration
        public let spent: Duration

        public init(limit: Duration, spent: Duration) {
            self.limit = limit
            self.spent = spent
        }

        public var description: String { "its limit of \(limit) had passed before it could start, \(spent.milliseconds) ms after it was asked" }
    }
}

public extension Duration {
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
    var nanoseconds: Int64 { components.seconds &* 1_000_000_000 &+ components.attoseconds / 1_000_000_000 }
    /// Whole milliseconds, for the waits that take an `Int32` of them, as `poll` does.
    var wholeMilliseconds: Int32 { Int32(clamping: components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000) }
    var milliseconds: Int64 { components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000 }
    /// The span as a `timespec`, for `kevent`, none below zero.
    var timespec: Darwin.timespec {
        let span = max(.zero, self)
        return Darwin.timespec(tv_sec: Int(span.components.seconds), tv_nsec: Int(span.components.attoseconds / 1_000_000_000))
    }
}

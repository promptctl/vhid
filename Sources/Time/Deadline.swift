import Foundation

/// When a request is to be over, and the limit that put it there.
///
/// [LAW:no-ambient-temporal-coupling] Made only where a request enters - a reading, a CLI
/// verb, a client's call to vhidd, a sweep tick, the release a seat's ending owes - and
/// handed to everything below it. A lock, a condition, a poll or a kevent under it takes
/// this and never a span of its own, so the time a request spends waiting for a thread, a
/// lock or a turn is counted against the limit its caller gave, not started afresh after.
public struct Deadline: Sendable, CustomStringConvertible {
    /// What the request was given where it entered.
    public let limit: Duration
    public let at: Instant
    public let timeline: Timeline

    /// Over `limit` from now.
    public static func within(_ limit: Duration, on timeline: Timeline) -> Deadline {
        Deadline(limit: limit, at: timeline.now() + limit, timeline: timeline)
    }

    /// Over at `at`, an instant a caller made somewhere else: a client's deadline, as vhidd
    /// receives it. The limit is what was left of it on arrival.
    public static func at(_ at: Instant, on timeline: Timeline) -> Deadline {
        Deadline(limit: max(.zero, at - timeline.now()), at: at, timeline: timeline)
    }

    /// What is left of the limit, none once it has passed.
    public var left: Duration { max(.zero, at - timeline.now()) }
    public var passed: Bool { timeline.now() >= at }
    /// How long since the request entered.
    public var spent: Duration { timeline.now() - (at - limit) }

    /// Waits on `condition`, which the caller holds locked, until it is signalled or this
    /// passes, and answers whether any of the limit is left. A caller loops on what it is
    /// waiting for and asks this again; a test timeline that moves wakes it.
    public func wait(on condition: NSCondition) -> Bool {
        guard !passed else { return false }
        timeline.block(until: at, waking: { condition.lock(); condition.broadcast(); condition.unlock() }) { span in
            condition.wait(until: Date(timeIntervalSinceNow: span.seconds))
        }
        return !passed
    }

    /// One system wait toward this deadline - a `kevent`, a `poll`, a semaphore - that
    /// `wake` ends early. `sleep` is handed the real span it may block for, in whichever
    /// unit it takes, and answers whether it was woken before the span ran out.
    public func block(waking wake: @escaping @Sendable () -> Void, _ sleep: (Duration) -> Bool) {
        timeline.block(until: at, waking: wake, sleep)
    }

    /// A request refused because its limit had passed before its turn came.
    public var refusal: Passed { Passed(limit: limit, spent: spent) }

    public var description: String { "\(limit), \(left) left" }

    /// The request's limit passed while it waited, and it was let go before it ran anything.
    public struct Passed: Error, Equatable, CustomStringConvertible {
        public let limit: Duration
        public let spent: Duration

        public init(limit: Duration, spent: Duration) {
            self.limit = limit
            self.spent = spent
        }

        public var description: String { "its limit of \(limit) had passed when its turn came, \(spent.milliseconds) ms after it was asked" }
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

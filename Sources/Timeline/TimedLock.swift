import Foundation

/// A lock whose turn is waited for by a deadline, or for as long as the turn takes.
///
/// [LAW:single-enforcer] The one way a turn behind another is waited for, so the wait is
/// either counted against the limit of whoever waits or is said, in its name, to be
/// unbounded. An act a client waits on takes its turn by the act's deadline: a lock taken
/// without one is a queue that act sits in for as long as the acts ahead take, past the
/// time its client is still listening, and then acts for a client already told it failed.
/// A release of what a client left held takes its turn however long it takes, since one
/// given up on is a key left down; the wait still ends, because whatever is ahead of it
/// holds the lock no longer than its own deadline.
///
/// On `Deadline.wait(on:)`, so a timeline a test moves wakes a waiter whose deadline it
/// moved past.
public final class TimedLock: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false

    public init() {}

    /// Runs `body` holding the lock, once it is this caller's turn by `deadline`, or throws
    /// `Late` without running it. A lock free when asked is taken whatever the deadline.
    public func withLock<T>(by deadline: Deadline, _ body: () throws -> T) throws -> T {
        condition.lock()
        while held {
            guard !deadline.passed else {
                condition.unlock()
                throw Late(limit: deadline.limit)
            }
            deadline.wait(on: condition)
        }
        return try holding(body)
    }

    /// Runs `body` holding the lock, however long the turn takes to come: for what must
    /// happen whatever it waits for.
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        while held { condition.wait() }
        return try holding(body)
    }

    /// Runs `body` holding the lock when nobody holds it now, and answers `.busy` without
    /// running it when somebody does.
    public func whenFree<T>(_ body: () throws -> T) rethrows -> Turn<T> {
        condition.lock()
        guard !held else {
            condition.unlock()
            return .busy
        }
        return .took(try holding(body))
    }

    /// What a try at a lock that was not waited for came to.
    public enum Turn<T> {
        case took(T)
        case busy
    }

    /// Takes the lock, which the caller found free under the condition, runs `body`
    /// outside the condition, and hands the lock to whoever waits next. Every waiter is
    /// woken, since each waits by its own deadline and the first to look may be one whose
    /// deadline has passed.
    private func holding<T>(_ body: () throws -> T) rethrows -> T {
        held = true
        condition.unlock()
        defer {
            condition.lock()
            held = false
            condition.broadcast()
            condition.unlock()
        }
        return try body()
    }
}

/// A turn that did not come by its deadline: refused before anything of it was done.
public struct Late: Error, CustomStringConvertible {
    public let limit: Duration
    public init(limit: Duration) { self.limit = limit }
    public var description: String { "this call's turn had not come by its limit of \(limit), so nothing of it was done" }
}

import Foundation

/// A lock a request takes by its deadline.
///
/// [LAW:single-enforcer] The one place a request's turn is judged: a waiter whose deadline
/// passed while it slept is refused before it runs anything, so work that comes too late to
/// be answered is never done. A plain lock lets it through whenever its turn comes, and its
/// caller has been told it failed by then.
public final class TimedLock: @unchecked Sendable {
    private let condition = NSCondition()
    /// Under `condition`.
    private var held = false

    public init() {}

    /// Runs `body` holding the lock, or throws `Deadline.Passed` when the deadline passes
    /// first - already passed on arrival, or passed while it waited - having run nothing.
    public func withLock<T>(by deadline: Deadline, _ body: () throws -> T) throws -> T {
        condition.lock()
        while true {
            guard !deadline.passed else { condition.unlock(); throw deadline.refusal }
            guard held else { break }
            _ = deadline.wait(on: condition)
        }
        held = true
        condition.unlock()
        defer { letGo() }
        return try body()
    }

    /// Runs `body` holding the lock, however long the wait for it. Only for a release: the
    /// letting go of what is held has to happen whoever is ahead of it, and refusing it would
    /// leave a key down.
    public func releasing<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        while held { condition.wait() }
        held = true
        condition.unlock()
        defer { letGo() }
        return try body()
    }

    /// Runs `body` holding the lock if nobody holds it now, and runs nothing otherwise: for
    /// the sweep, which never waits behind a client's act.
    public func whenFree<T>(_ body: () throws -> T) rethrows -> T? {
        condition.lock()
        guard !held else { condition.unlock(); return nil }
        held = true
        condition.unlock()
        defer { letGo() }
        return try body()
    }

    private func letGo() {
        condition.lock()
        held = false
        condition.broadcast()
        condition.unlock()
    }
}

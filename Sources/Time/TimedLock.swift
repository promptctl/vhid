import Foundation

/// A lock acquired with a deadline as its timeout, as C++'s `timed_mutex` is with
/// `try_lock_until`.
///
/// [LAW:single-enforcer] The one place a waiter's deadline is checked as it acquires the
/// lock: a waiter whose deadline passed while it slept is refused before it runs anything,
/// so work that comes too late to be answered is never done. A plain lock lets it through
/// whenever the lock comes free, and its caller has been told it failed by then.
public final class TimedLock: @unchecked Sendable {
    private let condition = NSCondition()
    /// Under `condition`.
    private var held = false

    public init() {}

    /// Runs `body` holding the lock, or throws `Deadline.Exceeded` when the deadline passes
    /// first - already passed on arrival, or passed while it waited - having run nothing.
    public func withLock<T>(by deadline: Deadline, _ body: () throws -> T) throws -> T {
        condition.lock()
        while true {
            guard !deadline.expired else { condition.unlock(); throw deadline.exceeded }
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
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        condition.lock()
        while held { condition.wait() }
        held = true
        condition.unlock()
        defer { letGo() }
        return try body()
    }

    /// Runs `body` holding the lock if nobody holds it now, and runs nothing otherwise: for
    /// the sweep, which never waits behind a client's request.
    public func withLockIfAvailable<T>(_ body: () throws -> T) rethrows -> T? {
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

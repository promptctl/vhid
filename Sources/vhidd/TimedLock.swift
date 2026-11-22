import Foundation
import Timeline

/// A lock an act takes by its deadline, or is turned away from before it has done anything.
///
/// [LAW:single-enforcer] The one way an act waits for its turn behind another, so every such
/// wait is counted against the limit of the act that waits: a lock taken without one is a
/// queue a client's act sits in for as long as the acts ahead of it take, past the time the
/// client is still listening, and then acts on the devices for a client that has already
/// been told it failed.
final class TimedLock: Sendable {
    private let lock = NSLock()

    /// Runs `body` holding the lock, once it is this act's turn by `deadline`, or throws
    /// `Late` without running it.
    func withLock<T>(by deadline: Deadline, _ body: () throws -> T) throws -> T {
        // Around again for a wait that woke before its deadline's clock said it passed.
        while !lock.lock(before: deadline.date) {
            guard !deadline.passed else { throw Late(limit: deadline.limit) }
        }
        defer { lock.unlock() }
        return try body()
    }

    /// Runs `body` holding the lock, however long the turn takes to come: for what must
    /// happen whatever it waits, a release of what a client left held. The wait still ends,
    /// because everything else that holds the lock holds it by a deadline.
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// An act whose turn did not come by its deadline: refused before it reached the devices.
struct Late: Error, CustomStringConvertible {
    let limit: Duration
    var description: String { "the devices were still busy at this act's limit of \(limit), so nothing of it was sent" }
}

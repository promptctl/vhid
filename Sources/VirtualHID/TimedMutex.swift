import Foundation
import Timeline

/// A lock on `State` that a caller waits for by a deadline, on the clock the deadline is on.
///
/// A device holds its record across a report's round trip, so the next report waits for
/// the one ahead of it. [LAW:no-ambient-temporal-coupling] That wait is part of the
/// caller's limit: a report whose deadline passes before its turn comes throws `.unsent`,
/// which is what it is - nothing of it reached the daemon - rather than starting its limit
/// afresh once the lock is won.
final class TimedMutex<State>: @unchecked Sendable {
    private let condition = NSCondition()
    private let now: @Sendable () -> Duration
    /// Whether a holder has the state. The state is touched only by the holder, or by a
    /// reader under the condition while no one holds it.
    private var taken = false
    private var state: State

    init(_ state: State, now: @escaping @Sendable () -> Duration) {
        self.state = state
        self.now = now
    }

    /// Runs `body` with the state once no one else holds it, or throws `.unsent` when
    /// `deadline` passes first. Every holder letting go wakes the waiters, and each asks the
    /// clock again: one held still lets no deadline pass.
    func withLock<T>(by deadline: Duration, _ body: (inout State) throws -> T) throws -> T {
        condition.lock()
        while taken {
            let remaining = deadline - now()
            guard remaining > .zero else {
                condition.unlock()
                throw DaemonError.unsent
            }
            condition.wait(until: Date(timeIntervalSinceNow: remaining.seconds))
        }
        taken = true
        condition.unlock()
        defer {
            condition.lock()
            taken = false
            condition.broadcast()
            condition.unlock()
        }
        return try body(&state)
    }

    /// The state as the last holder left it. Waits for the holder there is, whose own
    /// deadline bounds it.
    func read<T>(_ body: (State) -> T) -> T {
        condition.lock(); defer { condition.unlock() }
        while taken { condition.wait() }
        return body(state)
    }
}

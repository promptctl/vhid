import Dispatch
import Synchronization

/// Where a device call waits for its acknowledgement: a serial queue of its own, off the
/// main actor and off the cooperative pool.
///
/// A report to the keyboard or the mouse blocks the thread it is made on until the far
/// side answers, and that wait is the pacing the driver needs, so it stays; what moves is
/// the thread. On the caller's own actor it held that actor for as long as the insert took
/// - ten seconds for a long sentence - so anything else that actor was responsible for
/// waited with it; the app this was written in lost its keyboard tap that way, and macOS
/// switches off a tap that cannot be heard. On the cooperative pool it would hold one of
/// the few threads the rest of the process runs on, which is how `HelperKeyboardTests`
/// once starved a three-core runner. A queue nothing else runs on is the one place the
/// wait holds up nobody. [LAW:no-ambient-temporal-coupling]
///
/// Serial, and one shared by the keyboard and the mouse a client posts through, because
/// the helper takes their reports as one sequence: two in flight at once would be ordered
/// by its lock rather than by the order they were asked in. A value handed to both rather
/// than a static, so one client never waits on another's. [LAW:no-shared-mutable-globals]
public final class DeviceQueue: Sendable {
    private let queue = DispatchQueue(label: "Input.DeviceQueue")

    public init() {}

    /// Puts `call` on the queue now, behind every call submitted before it, and hands back
    /// what to await for its answer. Synchronous on purpose: the order calls reach the
    /// device is the order `submit` was called in, which is plain program order - no
    /// actor, task or scheduler stands between asking and being in line.
    /// [LAW:no-ambient-temporal-coupling]
    public func submit(_ call: @escaping @Sendable () throws -> Void) -> Acknowledgement {
        let acknowledgement = Acknowledgement()
        queue.async { acknowledgement.resolve(Result(catching: call)) }
        return acknowledgement
    }

    /// Submits `call` and waits for its answer. Nonsending, so a caller's actor is where
    /// the submit happens, before anything suspends.
    public nonisolated(nonsending) func run(_ call: @escaping @Sendable () throws -> Void) async throws {
        try await submit(call).value()
    }
}

/// The answer to one submitted call: resolved once, on the queue, and awaited by whoever
/// holds it - before or after it resolves.
public final class Acknowledgement: Sendable {
    private enum State {
        case pending([CheckedContinuation<Void, any Error>])
        case answered(Result<Void, any Error>)
    }

    private let state = Mutex(State.pending([]))

    fileprivate init() {}

    fileprivate func resolve(_ answer: Result<Void, any Error>) {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, any Error>] in
            guard case .pending(let waiting) = state else { preconditionFailure("an acknowledgement is answered once") }
            state = .answered(answer)
            return waiting
        }
        for continuation in waiting { continuation.resume(with: answer) }
    }

    /// Returns once the call has run, throwing what it threw.
    public func value() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let answer = state.withLock { state -> Result<Void, any Error>? in
                switch state {
                case .answered(let answer): return answer
                case .pending(let waiting):
                    state = .pending(waiting + [continuation])
                    return nil
                }
            }
            if let answer { continuation.resume(with: answer) }
        }
    }
}

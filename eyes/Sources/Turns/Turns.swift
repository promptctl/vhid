/// A FIFO async mutex: one piece of work at a time, for a resource that serves one: the daemon, which serves
/// one client, and Vision, which crashes the process with two recognitions in flight.
///
/// **Not the order they were sent in.** A caller's turn is queued when its call reaches
/// this actor, and callers racing from the shared pool reach it either way round; among
/// the callers already waiting, turns come first come, first served. A caller that needs
/// one piece of work after another waits for the first to return.
/// [LAW:no-ambient-temporal-coupling] Exclusion is this actor's to own; order is the caller's.
///
/// The work runs in its caller's own task, so cancelling the caller cancels the work it is
/// running, and a caller cancelled while it waits leaves the queue at once, never waiting
/// out the turn ahead of it.
public actor Turns {
    private var held = false
    private var waiting: [(ticket: Int, resume: CheckedContinuation<Void, any Error>)] = []
    private var issued = 0

    public init() {}

    /// How many callers are waiting for a turn.
    var queued: Int { waiting.count }

    /// Runs `work` once every caller queued before this one has had its turn.
    public nonisolated func take<T>(_ work: () async throws -> T) async throws -> T {
        try await acquire()
        do {
            // A caller cancelled before its turn came never starts its work: not when no turn
            // was ahead of it, and not when the turn reached it before its withdrawal from
            // the queue did.
            try Task.checkCancellation()
            let done = try await work()
            await release()
            return done
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async throws {
        guard held else { held = true; return }
        issued += 1
        let ticket = issued
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, any Error>) in
                // In the same job as the queueing, so a cancel either came first and is seen
                // here, or comes after and finds the ticket queued.
                if Task.isCancelled { resume.resume(throwing: CancellationError()) } else { waiting.append((ticket, resume)) }
            }
        } onCancel: {
            Task { await self.withdraw(ticket) }
        }
    }

    /// Takes a waiting caller out of the queue, cancelled; one whose turn already came is
    /// running, and its own task carries the cancel to its work.
    private func withdraw(_ ticket: Int) {
        guard let index = waiting.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiting.remove(at: index).resume.resume(throwing: CancellationError())
    }

    /// Hands the turn to the next caller waiting, or frees it.
    private func release() {
        if waiting.isEmpty { held = false } else { waiting.removeFirst().resume.resume() }
    }
}

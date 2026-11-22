import Synchronization
import Testing
import Waiting
@testable import Turns

@Suite struct TurnsTests {
    /// Work sent together runs one piece after another, never interleaved.
    @Test func workTakesTurnsAndNeverOverlaps() async throws {
        actor Log { var lines: [String] = []; func note(_ s: String) { lines.append(s) } }
        let log = Log(), turns = Turns()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    try await turns.take(waited: {}) {
                        await log.note("\(name) begins"); await Task.yield(); await log.note("\(name) ends")
                    }
                }
            }
            try await group.waitForAll()
        }
        let lines = await log.lines
        #expect(lines.count == 6)
        for pair in stride(from: 0, to: lines.count, by: 2) {
            #expect(lines[pair].dropLast(7) == lines[pair + 1].dropLast(5), "\(lines) interleaves")
        }
    }

    /// A caller cancelled while it waits behind running work leaves at once, while that work
    /// is still running, and never runs its own; the turn after it still comes.
    @Test(.hangGuarded) func aWaiterCancelledBehindRunningWorkLeavesAtOnce() async throws {
        let turns = Turns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (began, begin) = AsyncStream<Void>.makeStream()
        let running = Task { try await turns.take(waited: {}) { begin.finish(); for await _ in gate { break } } }
        for await _ in began {}
        let ran = Mutex(false), waited = Mutex(false)
        let waiter = Task { try await turns.take(waited: { waited.withLock { $0 = true } }) { ran.withLock { $0 = true } } }
        // Queued behind the running work before it is cancelled.
        while await turns.queued == 0 { await Task.yield() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(!ran.withLock { $0 })
        // The wait a withdrawal cut short is a wait over, said to the caller who counts it.
        #expect(waited.withLock { $0 })
        open.yield()
        try await running.value
        #expect(try await turns.take(waited: {}) { "after" } == "after")
    }

    /// A caller cancelled as the turn ahead of it ends never runs its work, whichever comes
    /// first to this actor: the turn handed on, or the caller's withdrawal from the queue.
    @Test(.hangGuarded) func aWaiterCancelledAsTheTurnReachesItNeverRuns() async throws {
        let turns = Turns(), ran = Mutex(false)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let (began, begin) = AsyncStream<Void>.makeStream()
        let waiter = Mutex<Task<Void, any Error>?>(nil)
        let running = Task {
            try await turns.take(waited: {}) {
                begin.finish()
                for await _ in gate { break }
                // Cancelled from inside the turn, which is handed on the moment this returns.
                waiter.withLock { $0 }?.cancel()
            }
        }
        for await _ in began {}
        let queued = Task { try await turns.take(waited: {}) { ran.withLock { $0 = true } } }
        waiter.withLock { $0 = queued }
        while await turns.queued == 0 { await Task.yield() }
        open.yield()
        try await running.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(!ran.withLock { $0 }, "a caller withdrawn as its turn came ran its work")
    }

    /// A caller cancelled before it takes its turn never starts its work, even with no turn
    /// ahead of it, when the work would otherwise begin at once.
    @Test func workCancelledBeforeItsTurnNeverStarts() async throws {
        let turns = Turns(), started = Mutex(false)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await turns.take(waited: {}) { started.withLock { $0 = true }; return "ran" }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!started.withLock { $0 }, "the work started though its caller was cancelled")
    }

    /// Work that throws hands the turn on all the same.
    @Test func workThatThrowsHandsTheTurnOn() async throws {
        struct Refusal: Error {}
        let turns = Turns()
        await #expect(throws: Refusal.self) { try await turns.take(waited: {}) { throw Refusal() } }
        #expect(try await turns.take(waited: {}) { 1 } == 1)
    }
}

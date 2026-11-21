import Testing
import Turns

/// Work handed in together runs one piece after another, and a cancelled caller's never runs.
@Suite struct TurnsTests {
    actor Record { var log: [String] = []; func note(_ s: String) { log.append(s) } }

    @Test func workTakesTurnsAndNeverOverlaps() async throws {
        let turns = Turns(), record = Record()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for name in ["a", "b", "c"] {
                group.addTask {
                    try await turns.take {
                        await record.note("\(name) begins"); await Task.yield(); await record.note("\(name) ends")
                    }
                }
            }
            try await group.waitForAll()
        }
        let log = await record.log
        #expect(log.count == 6)
        for pair in stride(from: 0, to: log.count, by: 2) {
            #expect(log[pair].dropLast(7) == log[pair + 1].dropLast(5), "\(log) interleaves")
        }
    }

    /// Work whose caller is cancelled never runs, even behind work still running, and the
    /// turn after it still comes.
    @Test func cancelledWorkNeverRuns() async throws {
        let turns = Turns()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let running = Task { try await turns.take { for await _ in gate { break } } }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await turns.take { "ran" }
        }
        open.yield()
        try await running.value
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await turns.take { "after" } == "after")
    }

    /// A caller cancelled before it takes its turn never starts its work, even with no turn
    /// ahead of it, when the work would otherwise begin at once.
    @Test func workCancelledBeforeItsTurnNeverStarts() async throws {
        let turns = Turns(), record = Record()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await turns.take { await record.note("ran"); return "ran" }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await record.log.isEmpty, "the work started though its caller was cancelled")
    }
}

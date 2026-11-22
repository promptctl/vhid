import Foundation
import OwnThread
import Synchronization
import Testing
import ChildProcess

/// A reading's limit and its cancel count from the call, whatever else the process is
/// doing with its cores. Each test fills the pool behind `DispatchQueue.global()` first:
/// two items that never stop spinning for every core, queued ahead of the reading, which
/// is what the trajectory suites did to it on CI. A reading that waited on that pool
/// would never start, and the child's alarm would end it. Each runs in a process of its
/// own, because a full pool is the whole process's. [LAW:behavior-not-structure]
@Suite(.ownThread) struct ReadingTests {
    @Test func aReadingOnAFullPoolGivesUpAtItsLimit() async {
        await #expect(processExitsWith: .success) {
            let pool = FullPool()
            let taken = try await reading { stop in
                Result { try Command("/bin/sleep", "3600").run(by: .within(.milliseconds(100), or: stop)) }
            }
            pool.release()
            guard case .failure(let error) = taken, error is Command.Overran else { exit(1) }
        }
    }

    @Test func aReadingOnAFullPoolIsEndedByItsCancel() async {
        await #expect(processExitsWith: .success) {
            let pool = FullPool()
            let task = Task {
                try await reading { stop in
                    Result { try Command("/bin/sleep", "3600").run(by: .within(hangGuard, or: stop)) }
                }
            }
            task.cancel()
            let ended = await task.result
            pool.release()
            guard case .failure(let error) = ended, error is CancellationError else { exit(1) }
        }
    }
}

/// Every thread the pool will start, kept busy until released, with as many items again
/// queued behind them. The alarm turns a reading that never started into a failed exit
/// rather than a child that never ends.
private final class FullPool: Sendable {
    private let released = Atomic(false)

    init() {
        alarm(UInt32(hangGuard.components.seconds))
        for _ in 0..<2 * ProcessInfo.processInfo.activeProcessorCount {
            DispatchQueue.global().async { [self] in while !released.load(ordering: .relaxed) {} }
        }
    }

    func release() { released.store(true, ordering: .relaxed) }
}

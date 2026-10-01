import Dispatch
import Testing

/// Runs each test of a suite on a thread of its own, off Swift's cooperative pool.
///
/// The pool has one thread for each core and makes no more. A test that waits out a
/// timeout, a child process or a reply holds the one it was given until the wait is
/// over, so on a runner with three cores the fourth such test does not start until one
/// of the first three ends, and a test waiting on something that itself needs the pool
/// never ends at all. Here a wait holds a thread nothing else was promised.
/// [LAW:no-ambient-temporal-coupling]
public struct OwnThread: SuiteTrait, TestTrait, TestScoping {
    public let isRecursive = true

    public func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        try await withTaskExecutorPreference(Executor(), operation: function)
    }

    /// A serial queue for each job, which dispatch gives a thread whenever it has work,
    /// however many others are blocked: it draws on neither the cooperative pool nor the
    /// bounded pool behind `DispatchQueue.global()`. One for each job and not one for the
    /// test, because a test's child tasks run here too, and a test standing still for its
    /// child would hold the one queue the child was waiting in.
    private final class Executor: TaskExecutor {
        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            DispatchQueue(label: "OwnThread").async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
    }
}

extension Trait where Self == OwnThread {
    /// Every test this is put on runs on a thread of its own, so its waits hold up no
    /// other test.
    public static var ownThread: Self { Self() }
}

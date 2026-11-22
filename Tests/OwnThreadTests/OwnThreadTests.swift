import Foundation
import OwnThread
import Testing

/// The trait as a test meets it: its thread is not one of the pool's.
@Suite(.ownThread) struct OwnThreadTests {
    /// A test that stands still until the pool has run something for it. Under
    /// `make test` the pool is one thread wide, so without the trait the task below has
    /// nowhere to run while this waits on it, and the wait ends at the hang guard.
    @Test func aTestHoldingItsThreadLeavesThePoolFree() throws {
        let ran = Gate()
        Task { ran.open() }
        try ran.wait(for: "the pool to run a task while the test holds its thread")
    }

    /// A child task is run where its parent is, off the pool, and the parent may be
    /// standing still waiting for it. The child is given a thread of its own as well.
    @Test func aTestHoldingItsThreadLeavesItsChildrenFree() async throws {
        let ran = Gate()
        async let child: Void = ran.open()
        try ran.wait(for: "the child to run while the test holds its thread")
        _ = await child
    }
}

/// The pool the trait takes a test off, as `make test` sets it. With the pool one thread
/// wide, a test that holds that thread leaves a task nowhere to run; on a wider pool the
/// tests above would pass without the trait, and a test that needs the trait and lacks it
/// would stop nothing. What narrows the pool is read, not raced: a task that has not run
/// within some wait says nothing on a machine busy enough.
struct PoolTests {
    @Test func thePoolIsOneThreadWide() {
        #expect(ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1",
                "the pool has more than one thread, so a test that holds one goes unseen: run `make test`")
    }
}

import Foundation
import OwnThread
import Testing
import Waiting

/// The trait as a test meets it: its thread is not one of the pool's.
@Suite(.ownThread, .hangGuarded) struct OwnThreadTests {
    /// A test that stands still until the pool has run something for it. Under
    /// `make test` the pool is one thread wide, so without the trait the task below has
    /// nowhere to run while this waits on it. The guard only ends that hang as a failure.
    @Test func aTestHoldingItsThreadLeavesThePoolFree() throws {
        let ran = Latch(false)
        Task { ran.update { $0 = true } }
        try ran.wait(for: "the pool to run the task while the test held its thread") { $0 }
    }

    /// A child task is run where its parent is, off the pool, and the parent may be
    /// standing still waiting for it. The child is given a thread of its own as well.
    @Test func aTestHoldingItsThreadLeavesItsChildrenFree() async throws {
        let ran = Latch(false)
        async let child: Void = ran.update { $0 = true }
        try ran.wait(for: "the child to run while the test held its thread") { $0 }
        _ = await child
    }
}

/// The pool the trait takes a test off, as `make test` sets it. This suite has no trait.
struct PoolTests {
    /// With the pool one thread wide, a task has nowhere to run while a test holds that
    /// thread, however long it waits. On a wider pool it runs at once: the tests above
    /// would then pass without the trait, and a test that needs the trait and lacks it
    /// would stop nothing here.
    ///
    /// Read from what sets it and not by holding the thread a while: "the task never ran"
    /// has no event to wait for, and a wait that finds it unrun on a wide pool says only
    /// that the runner was busy.
    @Test func thePoolIsOneThreadWide() {
        #expect(ProcessInfo.processInfo.environment["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] == "1", "the pool has more than one thread, so a test that holds one goes unseen: run `make test`")
    }
}

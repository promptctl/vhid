import Dispatch
import OwnThread
import Testing

/// Whether `ran` was signalled within `bound`, holding the calling thread until then.
private func signalled(_ ran: DispatchSemaphore, within bound: DispatchTimeInterval) -> Bool {
    ran.wait(timeout: .now() + bound) == .success
}

/// The trait as a test meets it: its thread is not one of the pool's.
@Suite(.ownThread) struct OwnThreadTests {
    /// A test that stands still until the pool has run something for it. Under
    /// `make test` the pool is one thread wide, so without the trait the task below has
    /// nowhere to run while this waits on it. The bound only ends that hang as a failure.
    @Test func aTestHoldingItsThreadLeavesThePoolFree() {
        let ran = DispatchSemaphore(value: 0)
        Task { ran.signal() }
        #expect(signalled(ran, within: .seconds(10)), "the pool ran nothing while the test waited")
    }

    /// A child task is run where its parent is, off the pool, and the parent may be
    /// standing still waiting for it. The child is given a thread of its own as well.
    @Test func aTestHoldingItsThreadLeavesItsChildrenFree() async {
        let ran = DispatchSemaphore(value: 0)
        async let child = ran.signal()
        #expect(signalled(ran, within: .seconds(10)), "the child did not run while the test waited")
        _ = await child
    }
}

/// The pool the trait takes a test off, as `make test` sets it. This suite has no trait.
struct PoolTests {
    /// With the pool one thread wide, the task below has nowhere to run while this holds
    /// that thread, however long it waits. On a wider pool it runs at once: the test above
    /// would then pass without the trait, and a test that needs the trait and lacks it
    /// would stop nothing here.
    @Test func thePoolIsOneThreadWide() {
        let ran = DispatchSemaphore(value: 0)
        Task { ran.signal() }
        #expect(!signalled(ran, within: .milliseconds(100)), "the pool has more than one thread, so a test that holds one goes unseen: run `make test`")
    }
}

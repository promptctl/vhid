import Dispatch
import OwnThread
import Testing

/// The trait as a test meets it: its thread is not one of the pool's.
@Suite(.ownThread) struct OwnThreadTests {
    /// A test that stands still until the pool has run something for it. Under
    /// `make test` the pool is one thread wide, so without the trait the task below has
    /// nowhere to run while this waits on it. The bound only ends that hang as a failure.
    @Test func aTestHoldingItsThreadLeavesThePoolFree() {
        let ran = DispatchSemaphore(value: 0)
        Task { ran.signal() }
        #expect(ran.wait(timeout: .now() + .seconds(10)) == .success, "the pool ran nothing while the test waited")
    }
}

import Foundation
import TestClock
import Testing
import Timeline
@testable import VirtualHID
import Waiting

@Suite(.hangLimit) struct TimedMutexTests {
    /// A caller waiting for the lock spends its own deadline on the wait: held past it, the
    /// caller is unsent and its body never runs, while the holder goes on. The deadline is
    /// made before the wait begins, on a clock the test holds, so only the clock moving
    /// past it can end the wait.
    @Test func aWaitForTheLockEndsAtTheCallersDeadline() throws {
        let clock = ManualClock()
        let timeline = Timeline(clock)
        let mutex = TimedMutex(0, now: timeline.now)
        let holding = Latch<Bool>(), letGo = Latch<Bool>(), held = Latch<Bool>()
        DispatchQueue(label: "TimedMutexTests.holder").async {
            try? mutex.withLock(by: hangGuard) { value in
                value = 1
                holding.open()
                try? letGo.waitOpen("the test to let the holder go")
            }
            held.open()
        }
        try holding.waitOpen("the holder to take the lock")
        let deadline = timeline.now() + .milliseconds(200)
        let thrown = Latch<DaemonError?>(nil)
        DispatchQueue(label: "TimedMutexTests.waiter").async {
            do { try mutex.withLock(by: deadline) { _ in Issue.record("the waiter ran past its deadline") } }
            catch { thrown.update { $0 = error as? DaemonError } }
        }
        clock.advance(by: .milliseconds(200))
        #expect(try thrown.wait(for: "the waiter to give up") { $0 } == .unsent)
        letGo.open()
        try held.waitOpen("the holder to let go")
        #expect(mutex.read { $0 } == 1)
    }

    /// Once the holder lets go, a waiter whose deadline has not passed takes the lock.
    @Test func aWaiterWithinItsDeadlineTakesTheLockWhenItIsLetGo() throws {
        let clock = ManualClock()
        let timeline = Timeline(clock)
        let mutex = TimedMutex(0, now: timeline.now)
        let holding = Latch<Bool>(), letGo = Latch<Bool>()
        DispatchQueue(label: "TimedMutexTests.holder").async {
            try? mutex.withLock(by: hangGuard) { _ in
                holding.open()
                try? letGo.waitOpen("the test to let the holder go")
            }
        }
        try holding.waitOpen("the holder to take the lock")
        let took = Latch<Int?>(nil)
        DispatchQueue(label: "TimedMutexTests.waiter").async {
            took.update { $0 = try? mutex.withLock(by: hangGuard) { value in value += 1; return value } }
        }
        letGo.open()
        #expect(try took.wait(for: "the waiter to take the lock") { $0 } == 1)
    }
}

import Foundation
import OwnThread
import Testing
import TestClock
import Time

/// Acquiring a lock with a deadline as the timeout, on a test clock: what waits behind a
/// held lock, and what it is told when its limit passes there.
@Suite(.ownThread)
struct TimedLockTests {
    @Test func aWaiterWhoseLimitPassesBehindTheLockRunsNothing() async {
        let clock = ManualClock(), lock = TimedLock(), holding = Gate(), refused = Latch()
        let ran = Ran()
        let deadline = Deadline.within(.seconds(1), on: Clock(clock))
        Thread.detachNewThread { lock.withLockIfAvailable { holding.arrive() } }
        holding.arrived.wait()
        Thread.detachNewThread {
            #expect(throws: Deadline.Exceeded.self) { try lock.withLock(by: deadline) { ran.mark() } }
            refused.open()
        }
        // The waiter is behind the lock; the clock moving past its limit wakes it there.
        clock.advance(by: .milliseconds(999))
        clock.advance(by: .milliseconds(1))
        refused.wait("the waiter to be refused")
        holding.open()
        #expect(!ran.marked)
    }

    @Test func aWaiterWhoseLimitHoldsRunsWhenTheLockIsLetGo() async {
        let clock = ManualClock(), lock = TimedLock(), holding = Gate(), served = Latch()
        let deadline = Deadline.within(.seconds(1), on: Clock(clock))
        Thread.detachNewThread { lock.withLockIfAvailable { holding.arrive() } }
        holding.arrived.wait()
        Thread.detachNewThread {
            #expect(throws: Never.self) { try lock.withLock(by: deadline) {} }
            served.open()
        }
        clock.advance(by: .milliseconds(500))
        holding.open()
        served.wait("the waiter to be served")
    }

    @Test func aRequestThatArrivesPastItsLimitIsRefusedAtAFreeLock() {
        let clock = ManualClock(), lock = TimedLock()
        let deadline = Deadline.within(.seconds(1), on: Clock(clock))
        clock.advance(by: .seconds(2))
        #expect(throws: Deadline.Exceeded(limit: .seconds(1), spent: .seconds(2))) { try lock.withLock(by: deadline) {} }
    }

    @Test func theSweepRunsNothingWhileTheLockIsHeld() {
        let lock = TimedLock(), holding = Gate(), letGo = Latch()
        Thread.detachNewThread { lock.withLockIfAvailable { holding.arrive() }; letGo.open() }
        holding.arrived.wait()
        #expect(lock.withLockIfAvailable { true } == nil)
        holding.open()
        letGo.wait()
        #expect(lock.withLockIfAvailable { true } == true)
    }

    @Test func aDeadlineFromTheWireKeepsItsInstant() {
        let clock = ManualClock()
        let sent = Deadline.within(.seconds(5), on: Clock(clock))
        clock.advance(by: .seconds(2))
        let received = Deadline.at(Instant(nanoseconds: sent.at.nanoseconds), on: Clock(clock))
        #expect(received.at == sent.at)
        #expect(received.limit == .seconds(3))
    }
}

private final class Ran: @unchecked Sendable {
    private let lock = NSLock()
    private var was = false
    func mark() { lock.withLock { was = true } }
    var marked: Bool { lock.withLock { was } }
}

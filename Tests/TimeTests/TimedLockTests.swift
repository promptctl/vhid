import Foundation
import OwnThread
import Testing
import TestClock
import Time

/// A request's turn at a lock, judged by its deadline on a test clock: what waits behind a
/// held lock, and what it is told when its limit passes there.
@Suite(.ownThread)
struct TimedLockTests {
    @Test func aWaiterWhoseLimitPassesBehindTheLockRunsNothing() async {
        let clock = ManualClock(), lock = TimedLock(), holding = Handshake(), refused = Latch()
        let ran = Ran()
        let deadline = Deadline.within(.seconds(1), on: clock.timeline)
        Thread.detachNewThread { lock.whenFree { holding.arrive() } }
        holding.reached.wait()
        Thread.detachNewThread {
            #expect(throws: Deadline.Passed.self) { try lock.withLock(by: deadline) { ran.mark() } }
            refused.open()
        }
        // The waiter is behind the lock; the clock moving past its limit wakes it there.
        clock.advance(by: .milliseconds(999))
        clock.advance(by: .milliseconds(1))
        refused.wait("the waiter to be refused")
        holding.released.open()
        #expect(!ran.marked)
    }

    @Test func aWaiterWhoseLimitHoldsRunsWhenTheLockIsLetGo() async {
        let clock = ManualClock(), lock = TimedLock(), holding = Handshake(), served = Latch()
        let deadline = Deadline.within(.seconds(1), on: clock.timeline)
        Thread.detachNewThread { lock.whenFree { holding.arrive() } }
        holding.reached.wait()
        Thread.detachNewThread {
            #expect(throws: Never.self) { try lock.withLock(by: deadline) {} }
            served.open()
        }
        clock.advance(by: .milliseconds(500))
        holding.released.open()
        served.wait("the waiter to be served")
    }

    @Test func aRequestThatArrivesPastItsLimitIsRefusedAtAFreeLock() {
        let clock = ManualClock(), lock = TimedLock()
        let deadline = Deadline.within(.seconds(1), on: clock.timeline)
        clock.advance(by: .seconds(2))
        #expect(throws: Deadline.Passed(limit: .seconds(1), spent: .seconds(2))) { try lock.withLock(by: deadline) {} }
    }

    @Test func theSweepRunsNothingWhileTheLockIsHeld() {
        let lock = TimedLock(), holding = Handshake(), letGo = Latch()
        Thread.detachNewThread { lock.whenFree { holding.arrive() }; letGo.open() }
        holding.reached.wait()
        #expect(lock.whenFree { true } == nil)
        holding.released.open()
        letGo.wait()
        #expect(lock.whenFree { true } == true)
    }

    @Test func aDeadlineFromTheWireKeepsItsInstant() {
        let clock = ManualClock()
        let sent = Deadline.within(.seconds(5), on: clock.timeline)
        clock.advance(by: .seconds(2))
        let received = Deadline.at(Instant(nanoseconds: sent.at.nanoseconds), on: clock.timeline)
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

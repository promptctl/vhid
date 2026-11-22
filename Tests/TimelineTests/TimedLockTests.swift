import Foundation
import OwnThread
import TestClock
import Testing
import Timeline
import Waiting

/// A turn is waited for by the caller's deadline and no longer, and a lock that is free is
/// taken whatever is left of it. The deadlines are on a clock the test holds, so whose turn
/// came is decided by the test's moves and not by the runner's pace.
/// [LAW:behavior-not-structure]
@Suite(.ownThread, .hangGuarded) struct TimedLockTests {
    /// The holder of the lock until the test lets go, on a thread of its own.
    private func held(_ lock: TimedLock) throws -> Latch<Bool> {
        let (holding, go) = (Latch(false), Latch(false))
        Thread.detachNewThread {
            lock.withLock {
                holding.update { $0 = true }
                _ = try? go.wait(for: "the test to let the lock go") { $0 }
            }
        }
        try holding.wait(for: "the lock to be held") { $0 }
        return go
    }

    @Test func aTurnThatHasNotComeByItsDeadlineIsLateAndRunsNothing() throws {
        let (lock, clock) = (TimedLock(), ManualClock())
        let go = try held(lock)
        let outcome = Latch<Result<Bool, any Error>?>(nil)
        let deadline = Timeline(clock).deadline(within: .seconds(1))
        Thread.detachNewThread {
            outcome.update { $0 = Result { try lock.withLock(by: deadline) { true } } }
        }
        try clock.awaitBlocked("the second caller to wait its turn")
        clock.advance(by: .seconds(1))
        let late = try outcome.wait(for: "the second caller's outcome") { $0 }
        #expect(throws: Late.self) { try late.get() }
        go.update { $0 = true }
    }

    @Test func aTurnThatComesBeforeItsDeadlineRuns() throws {
        let (lock, clock) = (TimedLock(), ManualClock())
        let go = try held(lock)
        let outcome = Latch<Result<Bool, any Error>?>(nil)
        let deadline = Timeline(clock).deadline(within: .seconds(1))
        Thread.detachNewThread {
            outcome.update { $0 = Result { try lock.withLock(by: deadline) { true } } }
        }
        try clock.awaitBlocked("the second caller to wait its turn")
        go.update { $0 = true }
        #expect(try outcome.wait(for: "the second caller's outcome") { $0 }.get())
    }

    @Test func aFreeLockIsTakenWhateverIsLeftOfTheDeadline() throws {
        let clock = ManualClock()
        let deadline = Timeline(clock).deadline(within: .seconds(1))
        clock.advance(by: .seconds(2))
        #expect(try TimedLock().withLock(by: deadline) { true })
    }

    /// The sweep's way in: it never waits, so it never stands in an act's way.
    @Test func whenFreeRunsOnlyOnALockNobodyHolds() throws {
        let lock = TimedLock()
        guard case .took(true) = lock.whenFree({ true }) else { Issue.record("a free lock was not taken"); return }
        let go = try held(lock)
        guard case .busy = lock.whenFree({ Issue.record("ran on a held lock") }) else { Issue.record("a held lock was taken"); return }
        go.update { $0 = true }
    }
}

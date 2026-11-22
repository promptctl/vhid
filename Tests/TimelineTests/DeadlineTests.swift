import Foundation
import OwnThread
import TestClock
import Testing
import Timeline
import Waiting

/// A deadline counts from when it was made, whatever happens after: the time a caller then
/// spends waiting for a thread or a lock is time its limit has already counted.
@Suite(.ownThread) struct DeadlineTests {
    @Test func aDeadlineCountsFromWhenItWasMade() {
        let clock = ManualClock()
        let deadline = Timeline(clock).deadline(within: .milliseconds(200))
        clock.advance(by: .milliseconds(150))
        #expect(deadline.left == .milliseconds(50))
        #expect(!deadline.passed)
        clock.advance(by: .milliseconds(50))
        #expect(deadline.passed)
        #expect(deadline.limit == .milliseconds(200))
    }

    /// A blocking wait by a deadline of a clock the test holds is ended by the move that
    /// passes it, so a test of a timed wait waits on its own moves and not the runner's pace.
    @Test(.hangGuarded) func aBlockingWaitEndsWhenTheClockIsMovedPastItsDeadline() throws {
        let clock = ManualClock()
        let deadline = Timeline(clock).deadline(within: .seconds(5))
        let (condition, woke) = (NSCondition(), Latch(false))
        Thread.detachNewThread {
            condition.lock()
            while !deadline.passed { deadline.wait(on: condition) }
            condition.unlock()
            woke.update { $0 = true }
        }
        try clock.awaitBlocked("the wait to block")
        clock.advance(by: .seconds(5))
        try woke.wait(for: "the wait to end") { $0 }
    }

    @Test func whatIsLeftOfAPassedDeadlineIsNone() {
        let clock = ManualClock()
        let deadline = Timeline(clock).deadline(within: .milliseconds(10))
        clock.advance(by: .seconds(1))
        #expect(deadline.left == .zero)
    }

    @Test func aSpanIsReadInTheUnitsEachSystemWaitTakes() {
        let span = Duration.seconds(2) + .nanoseconds(1_500_000)
        #expect(span.wholeMilliseconds == 2001)
        #expect(span.nanoseconds == 2_001_500_000)
        #expect(span.timespec.tv_sec == 2 && span.timespec.tv_nsec == 1_500_000)
        #expect(span.seconds == 2.0015)
        #expect(Duration.seconds(Int64.max / 1000).wholeMilliseconds == .max)
    }
}

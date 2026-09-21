import Input
import Synchronization
import Testing

/// The two promises a clock makes that this one is here to keep better than
/// `ContinuousClock` does: it wakes when it was asked to, and it stops when it is told to.
///
/// [LAW:behavior-not-structure] Measured against the wall rather than against which system
/// call was made, because "wakes on time" and "returns when cancelled" are the only things
/// a caller can hold it to - and both were broken here in ways that compiled and passed.
///
/// **The bounds are loose on purpose.** Each asks whether something took five seconds or
/// thirty, which is the whole gap between working and broken here, and nothing finer: a
/// macos-15 runner has been measured freezing a `swift test` process for three and a half
/// seconds shortly after it starts, and a bound tight enough to catch a regression this
/// large has no reason to be tighter than that. Tightening these turns a real assertion
/// into a flaky one. [LAW:verifiable-goals]
@Suite struct WakingClockTests {
    /// Sleeps do not queue behind each other.
    ///
    /// This was the defect: the wait was held on a **serial** queue shared by the whole
    /// process, so a short sleep waited out the longest one in flight - measured at 1.986 s
    /// late for a 5 ms sleep behind a 2 s one. Two concurrent sleeps are two waits, never
    /// two turns.
    @Test func twoSleepsDoNotQueueBehindEachOther() async throws {
        let clock = WakingClock()
        let long = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(30))) }
        defer { long.cancel() }
        let began = ContinuousClock.now
        try await clock.sleep(until: clock.now.advanced(by: .milliseconds(5)))
        #expect(began.duration(to: .now) < .seconds(5))
    }

    /// A cancelled sleep returns rather than running to its deadline.
    ///
    /// `mach_wait_until` cannot be interrupted, so what is asserted is what the caller
    /// sees: the task ends promptly and with a `CancellationError`, whatever the thread
    /// holding the wait goes on doing.
    @Test func aCancelledSleepReturnsAtOnceAndNotAtItsDeadline() async throws {
        let clock = WakingClock()
        let began = ContinuousClock.now
        let sleeping = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(30))) }
        try await Task.sleep(for: .milliseconds(20))
        sleeping.cancel()
        await #expect(throws: CancellationError.self) { try await sleeping.value }
        #expect(began.duration(to: .now) < .seconds(5))
    }

    /// A task already cancelled never sleeps at all: the handler can fire before the wait
    /// is even set up, and the answer to that is to refuse the wait, not to hold one
    /// nobody will wake.
    @Test func aSleepOnAnAlreadyCancelledTaskDoesNotWait() async throws {
        let clock = WakingClock()
        let sleeping = Task { try await clock.sleep(until: clock.now.advanced(by: .seconds(30))) }
        sleeping.cancel()
        await #expect(throws: CancellationError.self) { try await sleeping.value }
    }

    /// A deadline already behind the clock returns instead of waiting forever for a time
    /// that will not come again.
    @Test func aDeadlineAlreadyPastDoesNotWait() async throws {
        let clock = WakingClock()
        let began = ContinuousClock.now
        try await clock.sleep(until: clock.now.advanced(by: .seconds(-5)))
        #expect(began.duration(to: .now) < .seconds(5))
    }

    /// And it does wake when it was asked to, which is the reason it exists.
    @Test func aSleepWakesAtItsDeadlineAndNotBeforeIt() async throws {
        let clock = WakingClock()
        let deadline = clock.now.advanced(by: .milliseconds(30))
        try await clock.sleep(until: deadline)
        #expect(ContinuousClock.now >= deadline)
    }
}

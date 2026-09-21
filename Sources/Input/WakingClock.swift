import Darwin
import Dispatch
import Synchronization

/// The continuous clock's time, with a sleep that wakes when it was asked to.
///
/// A `ContinuousClock.sleep` resumes one to two milliseconds late even with no tolerance,
/// which at 120 Hz is a large part of the interval. A thread blocked in `mach_wait_until`
/// wakes on a timer the kernel does not coalesce, so what is left late is the hop back to
/// the caller's actor, which is steady enough for `Player.lead` to cover with a short
/// watch of the clock. The shorter that watch, the less CPU a replay spends on it, and a
/// replay exists to measure something else's frames.
public struct WakingClock: Clock {
    public typealias Instant = ContinuousClock.Instant

    /// Where the blocking wait is held, and **concurrent, which is the whole of why this
    /// line is worth reading.**
    ///
    /// It was serial, and a serial queue makes every sleeper in the process queue behind
    /// the longest wait in flight: measured here, a 5 ms sleep returned 1.986 s late
    /// behind a 2 s one. A clock whose reason to exist is wake precision cannot be the
    /// thing that makes a wake late, and no `Clock` anywhere orders its sleepers against
    /// each other - two tasks sleeping are not two tasks taking turns.
    ///
    /// Shared rather than one per instance, and that is not `DeviceQueue`'s mistake made
    /// again: what that type refuses a static for is the *ordering*, which is shared state
    /// two clients can contend over. A concurrent queue holds no order and no state, so
    /// what is shared here is a place to block and nothing else.
    /// [LAW:no-shared-mutable-globals] `twoSleepsDoNotQueueBehindEachOther` holds it.
    private static let waiter = DispatchQueue(label: "Input.WakingClock", qos: .userInteractive, attributes: .concurrent)
    private static let timebase = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return info
    }()

    public init() {}

    public var now: Instant { ContinuousClock.now }
    public var minimumResolution: Duration { ContinuousClock().minimumResolution }

    /// How long one uninterruptible wait may be.
    ///
    /// `mach_wait_until` runs to its own deadline whatever the caller does, so a wait of
    /// the whole remaining time is a worker thread held for that whole time even after the
    /// caller has gone. Enough long sleeps cancelled at once would take the queue's threads
    /// with them and leave the next sleeper waiting for one - which is the queueing that
    /// making this queue concurrent exists to prevent, arriving by another road.
    ///
    /// A second is the compromise: one wait for anything a replay actually asks for, so
    /// the common case costs nothing, and at most a second of a held thread outliving a
    /// cancel. The last wait is always the exact remainder, so nothing about this is paid
    /// for in precision. [LAW:no-ambient-temporal-coupling]
    private static let patience: Duration = .seconds(1)

    /// Sleeps until `deadline`, returning at once if the task is cancelled before then.
    ///
    /// A deadline already past does not wait at all.
    ///
    /// **Cancellation ends the wait for the caller before it ends for the thread.**
    /// `mach_wait_until` cannot be interrupted, so the thread holding the current wait runs
    /// to the end of it either way; what cancelling does is resume the caller immediately
    /// and leave that thread to finish alone, within `patience`, on a queue nothing is
    /// waiting behind. Waking periodically to ask instead would spend exactly the CPU this
    /// clock exists to save and would answer a cancel late rather than at once.
    /// [LAW:no-silent-failure] A sleep that ignored cancellation would hold a replay open
    /// for the full minute of a hold the caller had already stopped.
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        while true {
            try Task.checkCancellation()
            let remaining = now.duration(to: deadline)
            guard remaining > .zero else { return }
            await wait(for: min(remaining, Self.patience))
        }
    }

    /// One uninterruptible wait of `span`, which the caller may stop waiting on.
    ///
    /// The span is measured on `ContinuousClock` and waited out on `mach_absolute_time`,
    /// and those two disagree about one thing: the continuous clock runs while the Mac is
    /// asleep and the mach timer does not. A lid closed inside a wait therefore leaves the
    /// caller waiting past a deadline that has already come - by the length of the sleep,
    /// if this were the whole wait. It is not: `patience` caps one wait, and the loop above
    /// takes the next span from the continuous clock again, so the machine waking finds the
    /// deadline past and returns. A second is the whole of the exposure, and a replay
    /// interrupted by a lid closing has bigger problems than a second.
    private func wait(for span: Duration) async {
        let components = span.components
        let nanoseconds = UInt64(components.seconds) * 1_000_000_000 + UInt64(components.attoseconds / 1_000_000_000)
        let wake = mach_absolute_time() + nanoseconds * UInt64(Self.timebase.denom) / UInt64(Self.timebase.numer)
        let waking = Waking()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard waking.waits(on: continuation) else { return }
                Self.waiter.async {
                    mach_wait_until(wake)
                    waking.wake()
                }
            }
        } onCancel: {
            waking.wake()
        }
    }
}

/// One sleeper, woken once by whichever comes first: the deadline or the cancel.
///
/// [LAW:single-enforcer] Both racers call `wake`, and the lock is what makes exactly one
/// of them the one that resumes - a continuation resumed twice is a crash, and one never
/// resumed is a task that never returns. The cancel can also arrive before the
/// continuation exists, which is what `waits(on:)` answers false to: the handler runs at
/// once when the task is already cancelled, before the operation it guards has begun.
private final class Waking: Sendable {
    private let state = Mutex<(sleeper: CheckedContinuation<Void, Never>?, woken: Bool)>((nil, false))

    /// Holds the continuation, or refuses it because the wake already happened - in which
    /// case the caller resumes it itself and nothing is ever queued.
    func waits(on sleeper: CheckedContinuation<Void, Never>) -> Bool {
        let held = state.withLock { state -> Bool in
            guard !state.woken else { return false }
            state.sleeper = sleeper
            return true
        }
        if !held { sleeper.resume() }
        return held
    }

    func wake() {
        let sleeper = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.woken = true
            defer { state.sleeper = nil }
            return state.sleeper
        }
        sleeper?.resume()
    }
}

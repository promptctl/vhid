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

    /// Sleeps until `deadline`, returning at once if the task is cancelled before then.
    ///
    /// A deadline already past does not block the thread, since `mach_wait_until` returns
    /// for a time behind it, but the caller still pays the hop back to its actor.
    ///
    /// **Cancellation ends the wait for the caller, not for the thread.** `mach_wait_until`
    /// cannot be interrupted, so the thread holding it runs to the deadline either way;
    /// what cancelling does is resume the caller immediately and leave that thread to
    /// finish alone on a queue nothing is waiting behind. The alternative - waking every
    /// so often to ask - would spend exactly the CPU this clock exists to save, and would
    /// answer a cancel late rather than at once. [LAW:no-silent-failure] A sleep that
    /// ignored cancellation would hold a replay open for the full minute of a hold the
    /// caller had already stopped.
    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let remaining = max(.zero, now.duration(to: deadline)).components
        let nanoseconds = UInt64(remaining.seconds) * 1_000_000_000 + UInt64(remaining.attoseconds / 1_000_000_000)
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
        try Task.checkCancellation()
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

import Foundation
import Synchronization
import Timeline
import Waiting

/// A clock that moves only when told to, or when something sleeps until later than now.
public final class ManualClock: Clock {
    public struct Instant: InstantProtocol {
        public let offset: Duration
        public func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    public init() {}

    /// The time, and every condition something is blocked on by a deadline of this clock:
    /// under one lock, so a waiter that looked at the time before a move is one the move
    /// finds to wake. [LAW:no-ambient-temporal-coupling]
    private struct State {
        var current = Instant(offset: .zero)
        var blocked: [NSCondition] = []
    }

    private let state = Latch(State())
    private let slept = Mutex(0)
    /// What to do once something has slept here often enough, for a test that needs a
    /// stop to land inside a wait rather than at a report. [LAW:effects-at-boundaries]
    private let aim = Mutex<(after: Int, fire: (@Sendable () -> Void)?)>((.max, nil))

    public var now: Instant { state.current.current }
    public var minimumResolution: Duration { .zero }
    /// How many times something has slept on this clock.
    public var sleeps: Int { slept.withLock { $0 } }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let sleeps = slept.withLock { $0 += 1; return $0 }
        move { $0 = Swift.max($0, deadline) }
        aim.withLock { if sleeps >= $0.after { $0.fire?() } }
    }

    public func cancel(afterSleeps sleeps: Int, _ fire: @escaping @Sendable () -> Void) {
        aim.withLock { $0 = (sleeps, fire) }
    }

    public func advance(by duration: Duration) {
        move { $0 = $0.advanced(by: duration) }
    }

    /// Returns once something is blocked by a deadline of this clock: the moment a test
    /// may move the clock past it and know the move is what ends the wait.
    public func awaitBlocked(_ what: String) throws {
        try state.wait(for: what) { !$0.blocked.isEmpty }
    }

    /// Moves the time and wakes everything blocked on it, outside the clock's own lock: a
    /// waiter holds its condition while it registers here, so waking it under this lock
    /// would take the two in the other order.
    private func move(_ change: (inout Instant) -> Void) {
        var blocked: [NSCondition] = []
        state.update {
            change(&$0.current)
            blocked = $0.blocked
        }
        for condition in blocked {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Blocks on `condition` until a move wakes it, or returns at once when `until` has
    /// already come.
    private func block(_ condition: NSCondition, until: Duration) {
        var passed = false
        state.update {
            passed = $0.current.offset >= until
            if !passed { $0.blocked.append(condition) }
        }
        guard !passed else { return }
        condition.wait()
        state.update { blocked in
            blocked.blocked.remove(at: blocked.blocked.firstIndex { $0 === condition }!)
        }
    }

    /// This clock as a timeline whose blocking waits it wakes as it moves, chosen over the
    /// generic one for any clock of this type.
    public var timeline: Timeline {
        let origin = now
        return Timeline(
            now: { [self] in origin.duration(to: now) },
            sleep: { [self] in try await sleep(until: origin.advanced(by: $0), tolerance: .zero) },
            block: { [self] condition, until in block(condition, until: origin.offset + until) })
    }
}

public extension Timeline {
    /// A timeline on `clock` that a move of the clock reaches inside a blocking wait.
    init(_ clock: ManualClock) { self = clock.timeline }
}

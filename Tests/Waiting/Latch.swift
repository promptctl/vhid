import Dispatch
import Synchronization
import Timeline

/// How long a test waits for something that is going to happen before it calls the wait a
/// hang. Far past anything a loaded runner takes, so reaching it says the awaited event
/// never came, not that the machine was slow: no verdict turns on it.
/// [LAW:no-ambient-temporal-coupling] [LAW:one-source-of-truth] The one such bound in the
/// suites, so a wait for an event is never a race against a guessed time.
public let hangGuard: Duration = .seconds(60)

/// A wait that reached `hangGuard`: what was waited for never happened.
public struct Hung: Error, CustomStringConvertible {
    public let waitingFor: String

    public init(waitingFor: String) { self.waitingFor = waitingFor }

    public var description: String { "waited \(hangGuard) for \(waitingFor), which never came" }
}

/// A state the code under test changes and a test waits on a condition of: that a step was
/// reached, that a call was let go, that the third report came.
///
/// [LAW:no-ambient-temporal-coupling] An interleaving a test needs is forced by waiting
/// here for the state that proves it, never by sleeping for long enough. Every change
/// wakes the waiters whose condition it makes hold, so a wait ends the moment the event is
/// there, and only `hangGuard` ends one whose event never comes.
public final class Latch<State: Sendable>: Sendable {
    /// A wait still waiting: `offer` is handed each new state, keeps the value it finds in
    /// it for the waiter, and says whether it found one.
    private struct Waiter {
        let offer: @Sendable (State) -> Bool
        let woken: DispatchSemaphore
    }

    /// Where a woken waiter's value is kept until it takes it, read and written under the
    /// latch's lock only.
    private final class Slot<Value>: @unchecked Sendable {
        var found: Value?
    }

    /// The state, and the waiters still waiting.
    private let guarded: Mutex<(state: State, waiting: [Int: Waiter], next: Int)>

    public init(_ state: State) {
        guarded = Mutex((state, [:], 0))
    }

    public var state: State { guarded.withLock { $0.state } }

    /// Changes the state, and wakes every waiter whose condition the change makes hold.
    public func update(_ change: (inout State) -> Void) {
        guarded.withLock { guarded in
            change(&guarded.state)
            for (id, waiter) in guarded.waiting where waiter.offer(guarded.state) {
                guarded.waiting.removeValue(forKey: id)
                waiter.woken.signal()
            }
        }
    }

    /// Blocks until `holds` is true of the state, and returns the state it was true of.
    /// Throws `Hung`, naming `what`, at the guard.
    @discardableResult
    public func wait(for what: String, until holds: @escaping @Sendable (State) -> Bool) throws(Hung) -> State {
        try wait(for: what) { holds($0) ? $0 : nil }
    }

    /// Blocks until `taking` finds a value in the state, and returns it. Throws `Hung`,
    /// naming `what`, at the guard. [LAW:parse-dont-validate] The value `taking` found is
    /// the one handed back, kept as it was found, so nothing proves it twice.
    public func wait<Value>(for what: String, taking: @escaping @Sendable (State) -> Value?) throws(Hung) -> Value {
        let woken = DispatchSemaphore(value: 0)
        let slot = Slot<Value>()
        let id: Int? = guarded.withLock { guarded in
            if let found = taking(guarded.state) {
                slot.found = found
                return nil
            }
            guarded.next += 1
            guarded.waiting[guarded.next] = Waiter(offer: { state in
                slot.found = taking(state)
                return slot.found != nil
            }, woken: woken)
            return guarded.next
        }
        if let id { _ = woken.wait(timeout: .now() + .nanoseconds(Int(hangGuard.nanoseconds))) }
        // A change can land between the timeout and this lock: a waiter it already woke is
        // answered with what it found.
        let found: Value? = guarded.withLock { guarded in
            if let id { guarded.waiting.removeValue(forKey: id) }
            return slot.found
        }
        guard let found else { throw Hung(waitingFor: what) }
        return found
    }

    /// `wait(for:until:)` from a task, blocking a thread of its own rather than the task's:
    /// under `make test` the cooperative pool is one thread, and the change waited for may
    /// need it.
    @discardableResult
    public func value(for what: String, until holds: @escaping @Sendable (State) -> Bool) async throws(Hung) -> State {
        let waited: Result<State, Hung> = await withCheckedContinuation { waited in
            DispatchQueue(label: "Waiting.Latch").async {
                waited.resume(returning: Result { () throws(Hung) in try self.wait(for: what, until: holds) })
            }
        }
        return try waited.get()
    }
}

extension Latch where State == Bool {
    /// A latch shut until `open` is called, and open from then on.
    public convenience init() { self.init(false) }

    public func open() { update { $0 = true } }

    public func waitOpen(_ what: String) throws(Hung) { try wait(for: what) { $0 } }

    public func opened(_ what: String) async throws(Hung) { try await value(for: what) { $0 } }
}


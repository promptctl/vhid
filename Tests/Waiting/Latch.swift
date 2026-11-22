import Dispatch
import Synchronization

/// How long a test waits for something that is going to happen before it calls the wait a
/// hang. Far past anything a loaded runner takes, so reaching it says the awaited event
/// never came, not that the machine was slow: no verdict turns on it.
/// [LAW:no-ambient-temporal-coupling] [LAW:one-source-of-truth] The one such bound in the
/// suites, so a wait for an event is never a race against a guessed time.
public let hangGuard: Duration = .seconds(60)

/// A wait that reached `hangGuard`: what was waited for never happened.
public struct Hung: Error, CustomStringConvertible {
    public let waitingFor: String

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
    private struct Waiter {
        let holds: @Sendable (State) -> Bool
        let woken: DispatchSemaphore
    }

    /// The state, the waiters still waiting, and the state each woken waiter was woken by,
    /// until it takes it.
    private let guarded: Mutex<(state: State, waiting: [Int: Waiter], woken: [Int: State], next: Int)>

    public init(_ state: State) {
        guarded = Mutex((state, [:], [:], 0))
    }

    public var state: State { guarded.withLock { $0.state } }

    /// Changes the state, and wakes every waiter whose condition the change makes hold.
    public func update(_ change: (inout State) -> Void) {
        guarded.withLock { guarded in
            change(&guarded.state)
            for (id, waiter) in guarded.waiting where waiter.holds(guarded.state) {
                guarded.waiting.removeValue(forKey: id)
                guarded.woken[id] = guarded.state
                waiter.woken.signal()
            }
        }
    }

    /// Blocks until `holds` is true of the state, and returns the state it was true of.
    /// Throws `Hung`, naming `what`, at the guard.
    @discardableResult
    public func wait(for what: String, until holds: @escaping @Sendable (State) -> Bool) throws(Hung) -> State {
        let woken = DispatchSemaphore(value: 0)
        let asked: (held: State?, id: Int) = guarded.withLock { guarded in
            if holds(guarded.state) { return (guarded.state, 0) }
            guarded.next += 1
            guarded.waiting[guarded.next] = Waiter(holds: holds, woken: woken)
            return (nil, guarded.next)
        }
        if let held = asked.held { return held }
        let timedOut = woken.wait(timeout: .now() + .nanoseconds(Int(hangGuard.nanoseconds))) == .timedOut
        // A change can land between the timeout and this lock: a waiter it already woke is
        // answered with what woke it.
        let seen: State? = guarded.withLock { guarded in
            guarded.waiting.removeValue(forKey: asked.id)
            return guarded.woken.removeValue(forKey: asked.id)
        }
        guard let seen else {
            precondition(timedOut, "a latch's waiter woke with nothing to take")
            throw Hung(waitingFor: what)
        }
        return seen
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

private extension Duration {
    var nanoseconds: Int64 { components.seconds * 1_000_000_000 + components.attoseconds / 1_000_000_000 }
}

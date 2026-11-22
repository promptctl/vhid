import Foundation

/// How long a test waits on anything before it calls the wait a hang: far past any
/// answer on any machine, and short of the suites' one-minute time limit, so a hang is
/// reported by what was awaited rather than by the limit. Never a bound real work has to
/// beat. [LAW:one-source-of-truth] [LAW:no-ambient-temporal-coupling]
public let hangGuard: Duration = .seconds(30)

/// A wait that reached `hangGuard`, named by what it was waiting for.
public struct Hung: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "still waiting for \(what) after \(hangGuard)" }
}

/// A value the test waits on: whoever changes it wakes every waiter, and each waiter
/// returns once the value says what it was waiting for. The one way a test waits on an
/// event, so every wait is on the event itself and none on how long things take.
/// [LAW:one-type-per-behavior] [LAW:no-ambient-temporal-coupling]
public final class Gate<State>: @unchecked Sendable {
    private let condition = NSCondition()
    private var state: State

    public init(_ state: State) { self.state = state }

    /// What the value is now.
    public var now: State { condition.withLock { state } }

    public func update(_ change: (inout State) -> Void) {
        condition.withLock {
            change(&state)
            condition.broadcast()
        }
    }

    /// Blocks until `found` makes something of the value, for a test on a thread of its
    /// own.
    public func wait<T>(for what: String, until found: (State) -> T?) throws(Hung) -> T {
        let limit = Date(timeIntervalSinceNow: Double(hangGuard.components.seconds))
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let it = found(state) { return it }
            guard condition.wait(until: limit) else { throw Hung(what: what) }
        }
    }

    /// The same wait, for a test that must not hold its thread: it blocks a queue of its
    /// own instead.
    public func until<T: Sendable>(for what: String, _ found: @escaping @Sendable (State) -> T?) async throws(Hung) -> T {
        let waited: Result<T, Hung> = await withCheckedContinuation { waited in
            DispatchQueue(label: "Gate").async {
                waited.resume(returning: Result { () throws(Hung) -> T in try self.wait(for: what, until: found) })
            }
        }
        return try waited.get()
    }
}

extension Gate where State == Bool {
    /// A gate that is shut until it is opened once.
    public convenience init() { self.init(false) }
    public func open() { update { $0 = true } }
    public func wait(for what: String) throws(Hung) { try wait(for: what) { $0 ? () : nil } }
    public func until(for what: String) async throws(Hung) { try await until(for: what) { $0 ? () : nil } }
}

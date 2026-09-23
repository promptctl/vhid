import Foundation

/// Which connection has the keyboard. One at a time, because there is one keyboard: two
/// clients typing through the same set of held keys would each post reports missing the
/// other's, and the first to leave would release the keys the other was holding.
/// [LAW:types-are-the-program] Refusal is the truthful answer to a second client, and a
/// client that wants to share can connect per insert - the connection is lazy, and the
/// helper paid for readiness once.
///
/// Connections are named by identifier and not held: a holder that kept the connection
/// would keep it alive, and the release runs from a handler the connection itself owns.
final class Holder: @unchecked Sendable {
    struct Busy: Error, CustomStringConvertible {
        let pid: pid_t
        var description: String { "pid \(pid) holds the keyboard" }
    }

    private let lock = NSLock()
    private var holding: (connection: ObjectIdentifier, pid: pid_t)?

    /// The keyboard is `connection`'s until it is released, or `Busy` names whose it is.
    func claim(_ connection: ObjectIdentifier, by pid: pid_t) throws {
        lock.lock(); defer { lock.unlock() }
        if let holding { throw Busy(pid: holding.pid) }
        holding = (connection, pid)
    }

    /// Runs `body` while `connection` holds the devices, and reports whether it did. The
    /// lock is held across `body`, so no other connection can be admitted part way
    /// through it.
    func whileHolding(_ connection: ObjectIdentifier, _ body: () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard holding?.connection == connection else { return false }
        body()
        return true
    }

    /// Runs `body` and then frees the devices, when `connection` holds them, and changes
    /// nothing when it does not.
    ///
    /// Both under the one lock, so the next connection is admitted only after `body` -
    /// the release of everything this one left held - has finished.
    ///
    /// A connection that does not hold the devices runs nothing here, and that is what
    /// keeps its ending harmless. It may have been refused and never held them. Or it may
    /// have left already, and the devices may now be another client's. Releasing keys on
    /// its behalf would release the new holder's. [LAW:single-enforcer]
    func free(_ connection: ObjectIdentifier, after body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard holding?.connection == connection else { return }
        body()
        holding = nil
    }
}

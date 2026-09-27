import Foundation

/// Which connection has the devices: both of them, the keyboard and the mouse, whichever
/// of them its verbs use. One holder for both, because a release frees both as one act
/// (see `Devices`): two clients acting at once would each post reports missing the
/// other's, and the first to leave would release the keys and buttons the other held.
/// [LAW:types-are-the-program] Refusal is the truthful answer to a second client, and a
/// client that wants to share can connect per act - the connection is lazy, and
/// vhidd paid for readiness once.
///
/// Connections are named by identifier and not held: a holder that kept the connection
/// would keep it alive, and the release runs from a handler the connection itself owns.
final class Holder: @unchecked Sendable {
    struct Busy: Error, CustomStringConvertible {
        let pid: pid_t
        var description: String { "pid \(pid) holds the devices" }
    }

    private let lock = NSLock()
    private var holding: (connection: ObjectIdentifier, pid: pid_t, attempt: Int)?

    /// Runs `body` as `connection`'s act on the devices, claiming them for it first when
    /// nobody holds them, or throws `Busy` naming whose they are.
    ///
    /// The claim and the act under one lock, so no other connection can take the devices
    /// between them, and the devices are this connection's until it is freed. The claim is
    /// made by the first act and not at admission, so a connection that only asks who
    /// holds them never holds them. [LAW:single-enforcer]
    ///
    /// A hold on devices from an earlier attempt is no hold: those devices are gone.
    func serve(_ connection: ObjectIdentifier, by pid: pid_t, on attempt: Int, _ body: () -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if let holding, holding.connection != connection, holding.attempt == attempt { throw Busy(pid: holding.pid) }
        holding = (connection, pid, attempt)
        body()
    }

    /// The pid of whichever client holds the devices, or nil when none does.
    var pid: pid_t? {
        lock.lock(); defer { lock.unlock() }
        return holding?.pid
    }

    /// Runs `body` while `connection` holds the devices, and reports whether it did. The
    /// lock is held across `body`, so no other connection can claim them part way
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
    /// Both under the one lock, so the next connection can claim them only after `body` -
    /// the release of everything this one left held - has finished.
    ///
    /// A connection that does not hold the devices runs nothing here, and that is what
    /// keeps its ending harmless. It may have been refused and never held them. Or it may
    /// have left already, and the devices may now be another client's. Releasing keys and
    /// buttons on its behalf would release the new holder's. [LAW:single-enforcer]
    func free(_ connection: ObjectIdentifier, after body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard holding?.connection == connection else { return }
        body()
        holding = nil
    }
}

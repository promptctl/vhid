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
///
/// Its lock is held for the bookkeeping and never across an act or a release, so a second
/// client is told whose the devices are at once, and never waits behind the holder's acts
/// to be told it. A claim keeps the devices it was made on, so what is done on a holder's
/// behalf is done to its own devices and never to a later attempt's.
final class Holder: @unchecked Sendable {
    struct Busy: Error, CustomStringConvertible {
        let pid: pid_t
        var description: String { "pid \(pid) holds the devices" }
    }

    /// A connection's hold on the devices one attempt brought up.
    private struct Claim {
        let connection: ObjectIdentifier
        let pid: pid_t
        let up: Readiness.Up
    }

    private let lock = NSLock()
    private var holding: Claim?

    /// Claims `up`'s devices for `connection` when nobody holds them, or when it already
    /// does, or throws `Busy` naming whose they are.
    ///
    /// The claim is made by the first act and not at admission, so a connection that only
    /// asks who holds them never holds them. A hold on devices from an earlier attempt is
    /// no hold: those devices are gone. [LAW:single-enforcer]
    func claim(_ connection: ObjectIdentifier, by pid: pid_t, on up: Readiness.Up) throws(Busy) {
        lock.lock(); defer { lock.unlock() }
        if let holding, holding.connection != connection, holding.up.attempt == up.attempt { throw Busy(pid: holding.pid) }
        holding = Claim(connection: connection, pid: pid, up: up)
    }

    /// The pid of whichever client holds the devices `attempt` brought up, or nil when
    /// none does - a hold on an earlier attempt's devices holds nothing.
    func pid(on attempt: Int) -> pid_t? {
        lock.lock(); defer { lock.unlock() }
        return holding.flatMap { $0.up.attempt == attempt ? $0.pid : nil }
    }

    /// Runs `body` on the devices `connection` holds, when it holds any, and reports
    /// whether it did.
    func whileHolding(_ connection: ObjectIdentifier, _ body: (any ServedDevices) -> Void) -> Bool {
        guard let claim = claim(of: connection) else { return false }
        body(claim.up.devices)
        return true
    }

    /// Runs `release` on the devices `connection` holds and then frees them, when it holds
    /// any, and changes nothing when it does not.
    ///
    /// The claim stays the leaver's until `release` - of everything it left held - has
    /// finished, so the next client of those devices is refused as busy until then, and
    /// is never handed devices with the last one's keys still down.
    ///
    /// A connection that does not hold the devices runs nothing here, and that is what
    /// keeps its ending harmless. It may have been refused and never held them. Or it may
    /// have left already, and the devices may now be another client's. Releasing keys and
    /// buttons on its behalf would release the new holder's. [LAW:single-enforcer]
    func free(_ connection: ObjectIdentifier, after release: (any ServedDevices) -> Void) {
        guard let claim = claim(of: connection) else { return }
        release(claim.up.devices)
        lock.lock(); defer { lock.unlock() }
        // Only this claim: a client of devices brought up since may have claimed them.
        if holding?.connection == connection, holding?.up.attempt == claim.up.attempt { holding = nil }
    }

    private func claim(of connection: ObjectIdentifier) -> Claim? {
        lock.lock(); defer { lock.unlock() }
        return holding.flatMap { $0.connection == connection ? $0 : nil }
    }
}

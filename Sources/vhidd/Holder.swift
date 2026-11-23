import Foundation
import Synchronization

/// Which connection holds which bring-up's devices: both of them, the keyboard and the
/// mouse, whichever of them its verbs use. One holder for both, because a release frees
/// both in one step (see `Devices`): two clients sending at once would each post
/// reports missing the other's, and the first to leave would release the keys and buttons
/// the other held. [LAW:types-are-the-program] Refusal is the truthful answer to a second
/// client, and a client that wants to share can connect per request - the connection is lazy,
/// and vhidd paid for readiness once.
///
/// Bookkeeping and nothing else: it never runs or waits on a device, so its lock is held
/// for a comparison and an assignment, and whoever asks it is answered at once. The
/// devices own what may be held and every release of it. [LAW:decomposition]
///
/// Every acquire and free is judged against the bring-up it is asked about: a hold on an
/// earlier bring-up's devices is no hold, since those devices are gone.
///
/// Connections are named by identifier and not held: a holder that kept the connection
/// would keep it alive, and the release runs from a handler the connection itself owns.
final class Holder: Sendable {
    struct Busy: Error, CustomStringConvertible {
        let pid: pid_t
        var description: String { "pid \(pid) holds the devices" }
    }

    private let holding = Mutex<(connection: ObjectIdentifier, pid: pid_t, attempt: Int)?>(nil)

    /// Acquires `attempt`'s devices for `connection` when nobody holds them, or throws
    /// `Busy` naming whose they are. Acquired by the first request and not when the
    /// connection is accepted, so a connection that only asks who holds them never holds
    /// them. [LAW:single-enforcer]
    func acquire(for connection: ObjectIdentifier, by pid: pid_t, on attempt: Int) throws(Busy) {
        try holding.withLock { (holding) throws(Busy) in
            if let holding, holding.connection != connection, holding.attempt == attempt { throw Busy(pid: holding.pid) }
            holding = (connection, pid, attempt)
        }
    }

    /// Whether `connection` holds `attempt`'s devices.
    func holds(_ connection: ObjectIdentifier, on attempt: Int) -> Bool {
        holding.withLock { $0.map { $0.connection == connection && $0.attempt == attempt } ?? false }
    }

    /// The pid of whichever client holds `attempt`'s devices, or nil when none does.
    func pid(on attempt: Int) -> pid_t? {
        holding.withLock { $0.flatMap { $0.attempt == attempt ? $0.pid : nil } }
    }

    /// Frees `attempt`'s devices when `connection` holds them, and changes nothing when it
    /// does not. A connection that does not hold them may have been refused and never
    /// held them, or have left already with the devices now another client's: freeing
    /// them on its behalf would free the new holder's. [LAW:single-enforcer]
    func free(_ connection: ObjectIdentifier, on attempt: Int) {
        holding.withLock { holding in
            if let held = holding, held.connection == connection, held.attempt == attempt { holding = nil }
        }
    }
}

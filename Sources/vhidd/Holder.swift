import Foundation
import Timeline

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

    /// The last client's release failed, and so did this client's try at it: the devices
    /// may still hold what that client left down, and are handed to nobody until a
    /// release brings it up.
    struct LeftHeld: Error, CustomStringConvertible {
        let left: any Error
        let release: any Error
        var description: String {
            "the last client's keys or buttons may still be down (\(left)), and releasing them failed: \(release); nothing of this act was sent"
        }
    }

    /// A connection's hold on the devices one attempt brought up.
    private struct Claim {
        let connection: ObjectIdentifier
        let pid: pid_t
        let up: Readiness.Up
    }

    /// [LAW:types-are-the-program] Whose the devices are, or that they are fit for nobody
    /// yet: a client left and the release of what it held failed.
    private enum Holding {
        case nobody
        case held(Claim)
        case unreleased(Readiness.Up, Unreleased)
    }

    private let lock = NSLock()
    private var holding = Holding.nobody

    /// Claims `up`'s devices for `connection` when nobody holds them, or when it already
    /// does, or throws `Busy` naming whose they are.
    ///
    /// The claim is made by the first act and not at admission, so a connection that only
    /// asks who holds them never holds them. A hold on devices from an earlier attempt is
    /// no hold: those devices are gone. [LAW:single-enforcer]
    ///
    /// Devices a client left with a failed release are released again first, by this
    /// act's deadline, under this connection's claim, so no other client acts between the
    /// release and this act; when that fails too they stay unreleased and this act is
    /// refused as `LeftHeld`. The next client is never handed devices with the last one's
    /// keys still down.
    func claim(_ connection: ObjectIdentifier, by pid: pid_t, on up: Readiness.Up, by deadline: Deadline) throws {
        let claim = Claim(connection: connection, pid: pid, up: up)
        let left: Unreleased? = try locked {
            switch holding {
            case .held(let other) where other.connection != connection && other.up.attempt == up.attempt:
                throw Busy(pid: other.pid)
            case .unreleased(let devices, let left) where devices.attempt == up.attempt:
                holding = .held(claim)
                return left
            case .nobody, .held, .unreleased:
                holding = .held(claim)
                return nil
            }
        }
        guard let left else { return }
        do {
            try up.devices.release(by: deadline)
        } catch {
            locked { holding = .unreleased(up, left) }
            throw LeftHeld(left: left, release: error)
        }
    }

    /// The pid of whichever client holds the devices `attempt` brought up, or nil when
    /// none does - a hold on an earlier attempt's devices holds nothing.
    func pid(on attempt: Int) -> pid_t? {
        locked {
            guard case .held(let claim) = holding, claim.up.attempt == attempt else { return nil }
            return claim.pid
        }
    }

    /// Runs `body` on the devices `connection` holds, when it holds any.
    func whileHolding(_ connection: ObjectIdentifier, _ body: (any ServedDevices) -> Void) {
        claim(of: connection).map { body($0.up.devices) }
    }

    /// Runs `release` on the devices `connection` holds and then frees them, when it holds
    /// any, and changes nothing when it does not.
    ///
    /// The claim stays the leaver's until `release` - of everything it left held - has
    /// finished, so the next client of those devices is refused as busy until then. A
    /// release that failed leaves them unreleased rather than free, for the next claim to
    /// release again before it acts.
    ///
    /// A connection that does not hold the devices runs nothing here, and that is what
    /// keeps its ending harmless. It may have been refused and never held them. Or it may
    /// have left already, and the devices may now be another client's. Releasing keys and
    /// buttons on its behalf would release the new holder's. [LAW:single-enforcer]
    func free(_ connection: ObjectIdentifier, after release: (any ServedDevices) -> Release) {
        guard let claim = claim(of: connection) else { return }
        let released = release(claim.up.devices)
        locked {
            // Only this claim: a client of devices brought up since may have claimed them.
            guard case .held(let current) = holding, current.connection == connection, current.up.attempt == claim.up.attempt else { return }
            holding = switch released {
            case .released: .nobody
            case .failed(let why): .unreleased(claim.up, why)
            }
        }
    }

    private func claim(of connection: ObjectIdentifier) -> Claim? {
        locked {
            guard case .held(let claim) = holding, claim.connection == connection else { return nil }
            return claim
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}

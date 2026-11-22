import Foundation
import Helper
import Installations
import Time

/// Asking the daemon who holds the devices, and reading what came back.
///
/// [LAW:effects-at-boundaries] One `holding` call is the effect, made over the connection
/// every verb dials. It acquires nothing and sends no report, so asking it never takes the
/// devices from a client that holds them. What it came back as is read by a pure function
/// beside it, which a test drives with every failure a connection can end in.
public enum DaemonProbe {
    /// What this installation's daemon says, asked now and answered by `deadline`.
    public static func reading(of installation: Installation, by deadline: Deadline) -> DaemonReading {
        reading(by: deadline) { HelperConnection(installation: installation, clock: deadline.clock) }
    }

    /// What `holding` calls over fresh connections from `connect` came back as.
    ///
    /// A refused connection is asked about twice, on two connections. The client hears
    /// 4097 when the daemon refuses its signature and also when a daemon that was
    /// listening exits with the call in flight. A refused signature is refused again; a
    /// daemon that died is, the second time, whatever it is now - restarted and answering,
    /// or silent. Two refusals in a row is the signature. [LAW:no-silent-failure]
    static func reading(by deadline: Deadline, _ connect: () -> HelperConnection) -> DaemonReading {
        let first = asked(connect, by: deadline)
        guard first == .refusedThisVhid else { return first }
        return asked(connect, by: deadline)
    }

    /// [LAW:no-ambient-temporal-coupling] A deadline the rows before this one spent dials
    /// nothing: the daemon is not asked, and no connection is made to not ask it on.
    private static func asked(_ connect: () -> HelperConnection, by deadline: Deadline) -> DaemonReading {
        guard !deadline.expired else { return .unasked(deadline.exceeded) }
        do {
            return .answered(try connect().holding(by: deadline))
        } catch {
            return reading(failure: error)
        }
    }

    /// A `holding` call's failure, read by its cause.
    ///
    /// [LAW:types-are-the-program] By the domain and code the connection failed with, never
    /// by its words, which NSXPC makes the same for all of them. A daemon that refuses a
    /// connection ends it before it opens, which the client hears as an interrupted
    /// connection (4097); accepting a connection checks only the signature - a busy daemon
    /// refuses the first command, which a `holding` call never sends. A service nobody holds
    /// is an invalid one (4099). Anything else is shown as what it said.
    /// [LAW:no-silent-failure]
    ///
    /// A failure that is not the connection's is the daemon's own refusal, shown in the
    /// daemon's words.
    static func reading(failure error: any Error) -> DaemonReading {
        if let exceeded = error as? Deadline.Exceeded { return .unasked(exceeded) }
        if let refused = error as? HelperConnection.Refused {
            return refused.domain == Installation.refusalDomain && refused.code == Installation.devicesDownCode
                ? .devicesDown(reason: refused.reason)
                : .failed(reason: refused.reason)
        }
        guard let unreachable = error as? HelperConnection.Unreachable else { return .failed(reason: (error as NSError).localizedDescription) }
        switch unreachable.cause {
        case .connection(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted, description: _): return .refusedThisVhid
        case .connection(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid, description: _): return .unreachable(reason: "\(NSCocoaErrorDomain) \(NSXPCConnectionInvalid)")
        case .silence(let deadline): return .silent(reason: "no answer in \(deadline)")
        case .connection, .notAHelper, .abandoned: return .failed(reason: unreachable.description)
        }
    }
}

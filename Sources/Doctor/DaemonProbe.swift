import Foundation
import Helper
import Installations

/// Asking the daemon who holds the devices, and reading what came back.
///
/// [LAW:effects-at-boundaries] One `status` call is the effect, made over the connection
/// every verb dials. It claims nothing and sends no report, so asking it never takes the
/// devices from a client that holds them. What it came back as is read by a pure function
/// beside it, which a test drives with every failure a connection can end in.
public enum DaemonProbe {
    /// What this installation's daemon says, asked now.
    public static func reading(of installation: Installation, replyTimeout: Duration = .seconds(5)) -> DaemonReading {
        reading { HelperConnection(installation: installation, replyTimeout: replyTimeout) }
    }

    /// What status calls over fresh connections from `connect` came back as.
    ///
    /// A refused connection is asked about twice, on two connections. The client hears
    /// 4097 when the daemon refuses its signature and also when a daemon that was
    /// listening exits with the call in flight. A refused signature is refused again; a
    /// daemon that died is, the second time, whatever it is now - restarted and answering,
    /// or silent. Two refusals in a row is the signature. [LAW:no-silent-failure]
    static func reading(_ connect: () -> HelperConnection) -> DaemonReading {
        let first = asked(connect())
        guard first == .refusedThisSignature else { return first }
        return asked(connect())
    }

    private static func asked(_ helper: HelperConnection) -> DaemonReading {
        do {
            return .answered(holder: try helper.status())
        } catch {
            return reading(failure: error)
        }
    }

    /// A status call's failure, read by its cause.
    ///
    /// [LAW:types-are-the-program] By the domain and code the connection failed with, never
    /// by its words, which NSXPC makes the same for all of them. A daemon that refuses a
    /// connection ends it before it opens, which the client hears as an interrupted
    /// connection (4097); admission refuses only on the signature - a busy daemon is
    /// refused at the first act, which a status call never makes. A service nobody holds
    /// is an invalid one (4099). Anything else is shown as what it said.
    /// [LAW:no-silent-failure]
    ///
    /// A failure that is not the connection's is the daemon's own reply, which crosses as
    /// a plain `NSError` carrying its words as the localized description - so those words
    /// are what is shown, not the error's debug rendering.
    static func reading(failure error: any Error) -> DaemonReading {
        guard let unreachable = error as? HelperConnection.Unreachable else { return .failed(reason: (error as NSError).localizedDescription) }
        switch unreachable.cause {
        case .connection(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted, description: _): return .refusedThisSignature
        case .connection(domain: NSCocoaErrorDomain, code: NSXPCConnectionInvalid, description: _): return .unreachable(reason: unreachable.description)
        case .silence: return .silent(reason: unreachable.description)
        case .connection, .notAHelper: return .failed(reason: unreachable.description)
        }
    }
}

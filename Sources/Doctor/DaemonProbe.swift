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
    /// What status calls over fresh connections from `connect` came back as.
    ///
    /// A refused connection is asked about twice, on two connections. The client hears
    /// 4097 when the daemon refuses its signature and also when a daemon that was
    /// listening exits with the call in flight. A refused signature is refused again; a
    /// daemon that died is, the second time, whatever it is now - restarted and answering,
    /// or silent. Two refusals in a row is the signature. [LAW:no-silent-failure]
    ///
    /// Each call is let start by `admit`, which answers how long it may wait for the reply
    /// or throws where it is not to be made at all - a reading's limit spent, or its stop
    /// pulled - and that is `unasked`, with nothing asked. A second call never made says
    /// nothing against the first, so the refusal heard stands. [LAW:no-silent-failure]
    static func reading(admit: () throws -> Duration, _ connect: (Duration) -> HelperConnection) -> DaemonReading {
        let first = asked(admit, connect)
        guard first == .refusedThisVhid else { return first }
        let second = asked(admit, connect)
        if case .unasked = second { return first }
        return second
    }

    private static func asked(_ admit: () throws -> Duration, _ connect: (Duration) -> HelperConnection) -> DaemonReading {
        let wait: Duration
        do { wait = try admit() } catch { return .unasked(reason: "\(error)") }
        do {
            return .answered(holder: try connect(wait).status())
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
    /// A failure that is not the connection's is the daemon's own refusal, shown in the
    /// daemon's words.
    static func reading(failure error: any Error) -> DaemonReading {
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

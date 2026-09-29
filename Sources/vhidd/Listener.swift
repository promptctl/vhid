import Foundation
import Helper

/// Accepts a connection when the caller is who the requirement says, and refuses it
/// otherwise, saying why.
///
/// Whether the devices are free is not asked here: a connection holds them from its
/// first act, which its `Seat` claims. Refusing a busy daemon at admission would say
/// "busy" in the same NSError a refused signature says it in, and would turn away a
/// client that only wanted to ask who holds them. [LAW:single-enforcer]
final class Listener: NSObject, NSXPCListenerDelegate {
    private let readiness: Readiness
    private let callers: CallerIdentity
    private let cursor: any CursorSource
    private let holder = Holder()
    /// Checks for keys held past the limit a few times a second.
    private let sweep = DispatchSource.makeTimerSource(queue: .global())

    init(readiness: Readiness, callers: CallerIdentity, cursor: any CursorSource) {
        self.readiness = readiness
        self.cursor = cursor
        self.callers = callers
        super.init()
        sweep.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(100))
        sweep.setEventHandler { [readiness, holder] in releaseKeysHeldPastLimit(readiness, holder).map(log) }
        sweep.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            guard let token = connection.callerAuditToken else { throw CallerIdentity.Refused.noAuditToken }
            try callers.check(auditToken: token)
        } catch {
            logFailure("refused a connection from pid \(connection.processIdentifier): \(error)")
            return false
        }
        let id = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: HelperService.self)
        let seat = Seat(id, pid: connection.processIdentifier, holder: holder, readiness: readiness, cursor: cursor)
        connection.exportedObject = seat
        // Both, and not one: an interrupted connection ends invalid, a closed one ends
        // interrupted, and a client killed mid-burst can take either path. The release is
        // idempotent, so running it twice costs a report and running it never costs the
        // operator a held key. The devices are free for the next client only once this
        // one's keys and buttons are up, which is why invalidation frees the holder last.
        //
        // Each runs only while this connection still holds the devices. A client that left
        // first has already been released, and by the time its connection ends the devices
        // may be another client's, whose keys are not this ending's to release.
        //
        // Invalidation ends the seat and does not only free the holder: an act of this
        // client's still in flight would otherwise find the devices free and claim them
        // for a connection with no handler left to give them back.
        connection.invalidationHandler = { seat.end(because: "a client went away") }
        connection.interruptionHandler = { [readiness, holder] in
            _ = holder.whileHolding(id) { readiness.releaseEverything(because: "a client was interrupted") }
        }
        connection.resume()
        logRoutine("accepted a connection from pid \(connection.processIdentifier)")
        return true
    }
}

/// Lets go of keys a client has held past the limit and says whose they were. The holder
/// keeps the devices: the client's next act still works, and its own key-up is harmless.
///
/// The holder is read and the keys released under the holder's lock, in the order a
/// client's act takes the two locks, so the pid named is the one whose keys these were.
func releaseKeysHeldPastLimit(_ readiness: Readiness, _ holder: Holder) -> String? {
    guard let up = try? readiness.devices() else { return nil }
    return holder.withHolder(on: up.attempt) { pid in
        up.devices.releaseKeysHeldPastLimit().map { letGo in
            let keys = letGo.usages.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
            return "\(pid.map { "pid \($0)" } ?? "no client") held \(keys) past \(letGo.limit) with no report; "
                + (letGo.failure.map { "the keyboard would not release: \($0)" } ?? "released")
        }
    }
}

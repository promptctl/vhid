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
    private let devices: any ServedDevices
    private let callers: CallerIdentity
    private let holder = Holder()

    init(devices: any ServedDevices, callers: CallerIdentity) {
        self.devices = devices
        self.callers = callers
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            guard let token = connection.callerAuditToken else { throw CallerIdentity.Refused.noAuditToken }
            try callers.check(auditToken: token)
        } catch {
            log("refused a connection from pid \(connection.processIdentifier): \(error)")
            return false
        }
        let id = ObjectIdentifier(connection)
        connection.exportedInterface = NSXPCInterface(with: HelperService.self)
        connection.exportedObject = Seat(id, pid: connection.processIdentifier, holder: holder, devices: devices)
        // Both, and not one: an interrupted connection ends invalid, a closed one ends
        // interrupted, and a client killed mid-burst can take either path. The release is
        // idempotent, so running it twice costs a report and running it never costs the
        // operator a held key. The devices are free for the next client only once this
        // one's keys and buttons are up, which is why invalidation frees the holder last.
        //
        // Each runs only while this connection still holds the devices. A client that left
        // first has already been released, and by the time its connection ends the devices
        // may be another client's, whose keys are not this ending's to release.
        connection.invalidationHandler = { [devices, holder] in
            holder.free(id) { devices.releaseEverything(because: "a client went away") }
        }
        connection.interruptionHandler = { [devices, holder] in
            _ = holder.whileHolding(id) { devices.releaseEverything(because: "a client was interrupted") }
        }
        connection.resume()
        log("accepted a connection from pid \(connection.processIdentifier)")
        return true
    }
}

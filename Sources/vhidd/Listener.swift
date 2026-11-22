import Foundation
import Helper
import Time

/// Accepts a connection when the caller is who the requirement says, and refuses it
/// otherwise, saying why.
///
/// Whether the devices are free is not asked here: a connection holds them from its
/// first request, with which its `Seat` acquires them. Refusing the connection to a busy
/// daemon would say
/// "busy" in the same NSError a refused signature says it in, and would turn away a
/// client that only wanted to ask who holds them. [LAW:single-enforcer]
final class Listener: NSObject, NSXPCListenerDelegate {
    private let readiness: Readiness
    private let callers: CallerIdentity
    private let screen: any ScreenSource
    private let clock: Clock
    private let holder = Holder()
    /// Checks for keys held past the limit a few times a second, on a queue of its own: a
    /// tick that found the pool full would leave a key held as long as the pool stayed so.
    private let sweep = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "vhidd.sweep"))

    init(readiness: Readiness, callers: CallerIdentity, screen: any ScreenSource, clock: Clock) {
        self.readiness = readiness
        self.screen = screen
        self.callers = callers
        self.clock = clock
        super.init()
        sweep.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(100))
        sweep.setEventHandler { [readiness, holder] in vhidd.sweep(readiness, holder).map(log) }
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
        connection.exportedInterface = .helper()
        let seat = Seat(id, pid: connection.processIdentifier, holder: holder, readiness: readiness, screen: screen, clock: clock)
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
        // Invalidation ends the seat and does not only free the holder: a request of this
        // client's still in flight would otherwise find the devices free and acquire them
        // for a connection with no handler left to give them back.
        connection.invalidationHandler = { seat.end(because: "a client went away") }
        connection.interruptionHandler = { seat.interrupted() }
        connection.resume()
        logRoutine("accepted a connection from pid \(connection.processIdentifier)")
        return true
    }
}

/// Lets go of what has been held too long and says what it was: keys a client held past
/// the limit, and whose they were, or what a failed release left down while nobody holds
/// the devices. The holder keeps the devices: the client's next request still works, and its
/// own key-up is harmless.
///
/// The holder is read under the devices' lock, as a client's request acquires the devices,
/// so the pid
/// named is the one whose keys these were. A release of what was left stuck says its own
/// outcome as it is made, so it adds no line here.
func sweep(_ readiness: Readiness, _ holder: Holder) -> String? {
    guard let up = readiness.up else { return nil }
    switch up.devices.sweep(holding: { holder.pid(on: up.attempt) }) {
    case .keysPastLimit(let letGo, let pid):
        let keys = letGo.usages.map { String(format: "0x%02X", $0) }.joined(separator: ", ")
        return "\(pid.map { "pid \($0)" } ?? "no client") held \(keys) past \(letGo.limit) with no report; "
            + (letGo.failure.map { "the keyboard would not release: \($0)" } ?? "released")
    case .stuck, nil:
        return nil
    }
}

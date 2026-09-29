import Foundation
import Helper

/// One admitted connection's way to the devices, which closes when it leaves.
///
/// The listener used to hand every connection the devices themselves, which was right
/// while the only way to stop holding them was to disconnect. Now a client can leave and
/// keep its connection for a moment afterwards, so what it is handed has to know whose
/// seat it is. [LAW:single-enforcer]
///
/// The seat takes the devices on its first act, and an act while another seat holds them
/// is refused naming that client's pid. Admission checks only the signature, so a
/// connection that asks nothing but `status` sits here and holds nothing.
///
/// A seat ends once - its client leaves, or its connection ends - and every act after
/// that is refused by name and takes nothing. Both ways out go through `end`, so an act
/// already in flight when a client crashed cannot claim the devices for a connection with
/// nobody left to free them. [LAW:single-enforcer]
final class Seat: NSObject, HelperService, @unchecked Sendable {
    private let connection: ObjectIdentifier
    private let pid: pid_t
    private let holder: Holder
    private let readiness: Readiness
    private let cursor: any CursorSource
    /// Whether this seat has ended. Under its own lock across each act's claim, so an act
    /// cannot pass the check and then claim after `end` has freed the devices. Taken
    /// before the holder's lock and never after it.
    private let seat = NSLock()
    private var ended = false
    /// The attempt whose devices this seat has acted on. Devices lost and brought up again
    /// hold nothing this client set down, so a seat that held the lost ones ends rather
    /// than carrying on as if its keys were still down. [LAW:no-silent-failure]
    private var heldOn: Int?

    init(_ connection: ObjectIdentifier, pid: pid_t, holder: Holder, readiness: Readiness, cursor: any CursorSource) {
        self.connection = connection
        self.cursor = cursor
        self.pid = pid
        self.holder = holder
        self.readiness = readiness
    }

    /// [LAW:dataflow-not-control-flow] Every act is the same act: the devices, claimed for
    /// this seat if they are up and nobody holds them, and the refusal otherwise. Up is
    /// asked first, so a client turned away while they are down holds nothing and the next
    /// is told why too, not that the first one is in the way.
    private func serve(_ reply: @escaping (Error?) -> Void, _ act: (any ServedDevices) -> Void) {
        seat.lock(); defer { seat.unlock() }
        do {
            guard !ended else { throw Ended() }
            let up = try readiness.devices()
            if let heldOn, heldOn != up.attempt {
                ended = true
                holder.free(connection) {}
                throw Lost()
            }
            try holder.serve(connection, by: pid, on: up.attempt) { act(up.devices) }
            heldOn = up.attempt
        } catch {
            reply(refusal(error))
        }
    }

    func down(usage: UInt16, reply: @escaping (Error?) -> Void) { serve(reply) { $0.down(usage: usage, reply: reply) } }
    func releaseAll(reply: @escaping (Error?) -> Void) { serve(reply) { $0.releaseAll(reply: reply) } }
    func hold(usages: [UInt16], reply: @escaping (Error?) -> Void) { serve(reply) { $0.hold(usages: usages, reply: reply) } }
    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { serve(reply) { $0.buttonDown(button, reply: reply) } }
    func releaseButtons(reply: @escaping (Error?) -> Void) { serve(reply) { $0.releaseButtons(reply: reply) } }
    func holdButtons(_ buttons: UInt32, reply: @escaping (Error?) -> Void) { serve(reply) { $0.holdButtons(buttons, reply: reply) } }
    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { serve(reply) { $0.move(x: x, y: y, reply: reply) } }
    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) {
        serve(reply) { $0.scroll(vertical: vertical, horizontal: horizontal, reply: reply) }
    }

    /// Answered only once the devices are free, which is the whole point of asking.
    func leave(reply: @escaping (Error?) -> Void) {
        end(because: "a client left")
        reply(nil)
    }

    /// Ends this seat: no act after this is served, and the devices, if this seat holds
    /// them, are released and freed for the next client.
    func end(because reason: String) {
        seat.lock(); defer { seat.unlock() }
        ended = true
        holder.free(connection) { readiness.releaseEverything(because: reason) }
    }

    /// Who holds the devices, read and not claimed, or why they are not up.
    func status(reply: @escaping (NSNumber?, Error?) -> Void) {
        do {
            let up = try readiness.devices()
            reply(holder.pid(on: up.attempt).map { NSNumber(value: $0) }, nil)
        } catch {
            reply(nil, refusal(error))
        }
    }

    /// The daemon's last failure, answered whether or not the devices are up.
    func lastFailure(reply: @escaping (String?, Date?) -> Void) {
        let last = vhidd.lastFailure.current
        reply(last?.text, last?.at)
    }

    /// Where the cursor is in the session in front. Claims nothing, like `status`, and
    /// needs no devices: a read is not an act.
    func cursor(reply: @escaping (Double, Double, Error?) -> Void) {
        do {
            let at = try cursor.read()
            reply(at.x, at.y, nil)
        } catch {
            reply(0, 0, refusal(error))
        }
    }

    /// A call on a seat whose devices were lost under it.
    struct Lost: Error, CustomStringConvertible {
        var description: String { "the devices this connection held were lost and brought up again, releasing everything it held; connect again" }
    }

    /// A call on a seat that has ended.
    struct Ended: Error, CustomStringConvertible {
        var description: String { "this connection has already handed the devices back" }
    }
}

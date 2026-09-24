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
/// connection that asks nothing but `status` sits here and holds nothing. After `leave`,
/// every act is refused by name, and none of them takes the devices back.
final class Seat: NSObject, HelperService, @unchecked Sendable {
    private let connection: ObjectIdentifier
    private let pid: pid_t
    private let holder: Holder
    private let devices: any ServedDevices
    /// Whether this client has left. Held under its own lock across each act's claim, so
    /// an act cannot pass the check and then claim the devices after the leave has freed
    /// them. Taken before the holder's lock and never after it.
    private let seat = NSLock()
    private var hasLeft = false

    init(_ connection: ObjectIdentifier, pid: pid_t, holder: Holder, devices: any ServedDevices) {
        self.connection = connection
        self.pid = pid
        self.holder = holder
        self.devices = devices
    }

    /// [LAW:dataflow-not-control-flow] Every act is the same act: the devices, claimed for
    /// this seat if nobody holds them, and the refusal otherwise.
    private func serve(_ reply: @escaping (Error?) -> Void, _ act: () -> Void) {
        seat.lock(); defer { seat.unlock() }
        do {
            guard !hasLeft else { throw Left() }
            try holder.serve(connection, by: pid, act)
        } catch {
            reply(refusal(error))
        }
    }

    func down(usage: UInt16, reply: @escaping (Error?) -> Void) { serve(reply) { devices.down(usage: usage, reply: reply) } }
    func releaseAll(reply: @escaping (Error?) -> Void) { serve(reply) { devices.releaseAll(reply: reply) } }
    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { serve(reply) { devices.buttonDown(button, reply: reply) } }
    func releaseButtons(reply: @escaping (Error?) -> Void) { serve(reply) { devices.releaseButtons(reply: reply) } }
    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { serve(reply) { devices.move(x: x, y: y, reply: reply) } }
    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) {
        serve(reply) { devices.scroll(vertical: vertical, horizontal: horizontal, reply: reply) }
    }

    /// Answered only once the devices are free, which is the whole point of asking.
    func leave(reply: @escaping (Error?) -> Void) {
        seat.lock()
        hasLeft = true
        holder.free(connection) { devices.releaseEverything(because: "a client left") }
        seat.unlock()
        reply(nil)
    }

    /// Who holds the devices, read and not claimed.
    func status(reply: @escaping (NSNumber?, Error?) -> Void) {
        reply(holder.pid.map { NSNumber(value: $0) }, nil)
    }

    /// A call on a connection whose client already left.
    struct Left: Error, CustomStringConvertible {
        var description: String { "this connection has already handed the devices back" }
    }
}

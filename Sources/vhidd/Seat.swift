import Foundation
import Helper

/// One admitted connection's way to the devices, which closes when it leaves.
///
/// The listener used to hand every connection the devices themselves, which was right
/// while the only way to stop holding them was to disconnect. Now a client can leave and
/// keep its connection for a moment afterwards, so what it is handed has to know whose
/// seat it is. Every act is served only while this connection holds the devices, and is
/// refused by name after it has left. [LAW:single-enforcer]
final class Seat: NSObject, HelperService, @unchecked Sendable {
    private let connection: ObjectIdentifier
    private let holder: Holder
    private let devices: any ServedDevices

    init(_ connection: ObjectIdentifier, holder: Holder, devices: any ServedDevices) {
        self.connection = connection
        self.holder = holder
        self.devices = devices
    }

    /// [LAW:dataflow-not-control-flow] Every act is the same act: the devices, if this seat
    /// still holds them, and the refusal otherwise.
    private func serve(_ reply: @escaping (Error?) -> Void, _ act: () -> Void) {
        guard holder.whileHolding(connection, act) else { return reply(refusal(Left())) }
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
        holder.free(connection) { devices.releaseEverything(because: "a client left") }
        reply(nil)
    }

    /// A call on a connection whose client already left.
    struct Left: Error, CustomStringConvertible {
        var description: String { "this connection has already handed the devices back" }
    }
}

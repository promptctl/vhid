import Foundation
import Helper
import Timeline

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
///
/// An act has until a second before its client stops listening, counted from when it
/// arrived: its wait for this seat's turn and for the devices' is counted, and an act
/// whose turn comes too late is refused, as `Late`, while the client is still there to
/// hear it. Nothing is done on the devices for a client already told its act failed.
final class Seat: NSObject, HelperService, @unchecked Sendable {
    /// How long an act has, from when it arrives.
    static let actLimit = HelperConnection.replyTimeout - .seconds(1)

    private let connection: ObjectIdentifier
    private let pid: pid_t
    private let holder: Holder
    private let readiness: Readiness
    private let screen: any ScreenSource
    private let timeline: Timeline
    /// Whether this seat has ended. Under its own lock across each act, so an act cannot
    /// pass the check and then claim after `end` has freed the devices.
    private let seat = TimedLock()
    private var ended = false
    /// The attempt whose devices this seat has acted on. Devices lost and brought up again
    /// hold nothing this client set down, so a seat that held the lost ones ends rather
    /// than carrying on as if its keys were still down. [LAW:no-silent-failure]
    private var heldOn: Int?

    init(_ connection: ObjectIdentifier, pid: pid_t, holder: Holder, readiness: Readiness, screen: any ScreenSource, timeline: Timeline) {
        self.connection = connection
        self.screen = screen
        self.pid = pid
        self.holder = holder
        self.readiness = readiness
        self.timeline = timeline
    }

    /// [LAW:dataflow-not-control-flow] Every act is the same act: the devices, claimed for
    /// this seat if they are up and nobody holds them, the act on them by its deadline, and
    /// the answer, nil or the refusal. Up is asked first, so a client turned away while
    /// they are down holds nothing and the next is told why too, not that the first one is
    /// in the way.
    private func serve(_ reply: @escaping (Error?) -> Void, _ act: (any ServedDevices, Deadline) throws -> Void) {
        // Made before anything waits, so every wait below is counted against it.
        let deadline = timeline.deadline(within: Self.actLimit)
        do {
            try seat.withLock(by: deadline) {
                guard !ended else { throw Ended() }
                let up = try readiness.devices()
                if let heldOn, heldOn != up.attempt {
                    ended = true
                    holder.free(connection) { _ in }
                    throw Lost()
                }
                try holder.claim(connection, by: pid, on: up)
                heldOn = up.attempt
                try act(up.devices, deadline)
            }
            reply(nil)
        } catch {
            reply(refusal(error))
        }
    }

    func down(usage: UInt16, reply: @escaping (Error?) -> Void) { serve(reply) { try $0.down(usage: usage, by: $1) } }
    func releaseAll(reply: @escaping (Error?) -> Void) { serve(reply) { try $0.releaseAll(by: $1) } }
    func hold(usages: [UInt16], reply: @escaping (Error?) -> Void) { serve(reply) { try $0.hold(usages: usages, by: $1) } }
    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { serve(reply) { try $0.buttonDown(button, by: $1) } }
    func releaseButtons(reply: @escaping (Error?) -> Void) { serve(reply) { try $0.releaseButtons(by: $1) } }
    func holdButtons(_ buttons: UInt32, reply: @escaping (Error?) -> Void) { serve(reply) { try $0.holdButtons(buttons, by: $1) } }
    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { serve(reply) { try $0.move(x: x, y: y, by: $1) } }
    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) {
        serve(reply) { try $0.scroll(vertical: vertical, horizontal: horizontal, by: $1) }
    }

    /// Answered only once the devices are free, which is the whole point of asking.
    func leave(reply: @escaping (Error?) -> Void) {
        end(because: "a client left")
        reply(nil)
    }

    /// Ends this seat: no act after this is served, and the devices, if this seat holds
    /// them, are released and freed for the next client. After the act in flight, however
    /// long its turn takes: an ending given up on is a key left down.
    func end(because reason: String) {
        seat.withLock {
            ended = true
            holder.free(connection) { $0.releaseEverything(because: reason) }
        }
    }

    /// The connection was interrupted: what this seat holds is released, and the seat
    /// keeps the devices, under the seat's lock as an ending is, so the release is of this
    /// seat's own devices and is not made part way through its act.
    func interrupted() {
        seat.withLock {
            _ = holder.whileHolding(connection) { $0.releaseEverything(because: "a client was interrupted") }
        }
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
            let at = try screen.cursor()
            reply(at.x, at.y, nil)
        } catch {
            reply(0, 0, refusal(error))
        }
    }

    /// The display layout in the session in front, as its record. Claims nothing, like
    /// `cursor`.
    func layout(reply: @escaping ([NSNumber], Error?) -> Void) {
        do {
            reply(try screen.layout().record.map { NSNumber(value: $0) }, nil)
        } catch {
            reply([], refusal(error))
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

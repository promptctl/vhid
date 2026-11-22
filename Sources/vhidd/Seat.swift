import Foundation
import Helper
import Synchronization
import Time

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
    private let screen: any ScreenSource
    private let timeline: Timeline
    /// Whether this seat has ended, and the attempt whose devices it has acted on. Devices
    /// lost and brought up again hold nothing this client set down, so a seat that held
    /// the lost ones ends rather than carrying on as if its keys were still down.
    /// [LAW:no-silent-failure] Read and changed by an act only under the devices' lock, so
    /// an act cannot pass the check and then claim after `end` has freed the devices.
    private let state = Mutex<(ended: Bool, heldOn: Int?)>((false, nil))

    init(_ connection: ObjectIdentifier, pid: pid_t, holder: Holder, readiness: Readiness, screen: any ScreenSource, timeline: Timeline) {
        self.connection = connection
        self.screen = screen
        self.pid = pid
        self.holder = holder
        self.readiness = readiness
        self.timeline = timeline
    }

    /// [LAW:dataflow-not-control-flow] Every act is the same act: the client's deadline,
    /// the act parsed from the wire, the devices if they are up, and the act done once its
    /// turn comes and the seat is admitted to them - or the refusal. Nothing is claimed
    /// before the turn, so an act refused for its deadline, its values or the devices being
    /// down holds nothing, and the next client is told why too, not that the first one is
    /// in the way.
    ///
    /// [LAW:no-ambient-temporal-coupling] The deadline is the instant the client's call
    /// carries, made before anything is taken: vhidd makes no limit of its own for an act,
    /// and the wait for the devices counts against the client's.
    private func serve(by instant: UInt64, _ reply: (Error?) -> Void, _ asked: () throws -> Act) {
        let deadline = Deadline.at(Instant(nanoseconds: instant), on: timeline)
        do {
            let act = try asked()
            let up = try readiness.devices()
            try up.devices.act(act, by: deadline) { try admit(on: up.attempt) }
            reply(nil)
        } catch {
            reply(refusal(error))
        }
    }

    /// This seat admitted to `attempt`'s devices and holding them, or the refusal. Run
    /// under the devices' lock, once the act's turn has come.
    private func admit(on attempt: Int) throws {
        try state.withLock { state in
            guard !state.ended else { throw Ended() }
            if let heldOn = state.heldOn, heldOn != attempt {
                state.ended = true
                holder.free(connection, on: heldOn)
                throw Lost()
            }
            try holder.claim(for: connection, by: pid, on: attempt)
            state.heldOn = attempt
        }
    }

    func down(usage: UInt16, by deadline: UInt64, reply: @escaping (Error?) -> Void) { serve(by: deadline, reply) { try .down(usage: usage) } }
    func releaseAll(by deadline: UInt64, reply: @escaping (Error?) -> Void) { serve(by: deadline, reply) { .releaseKeys } }
    func hold(usages: [UInt16], by deadline: UInt64, reply: @escaping (Error?) -> Void) { serve(by: deadline, reply) { try .hold(usages: usages) } }
    func buttonDown(_ button: UInt8, by deadline: UInt64, reply: @escaping (Error?) -> Void) { serve(by: deadline, reply) { try .buttonDown(button) } }
    func releaseButtons(by deadline: UInt64, reply: @escaping (Error?) -> Void) { serve(by: deadline, reply) { .releaseButtons } }
    func holdButtons(_ buttons: UInt32, by deadline: UInt64, reply: @escaping (Error?) -> Void) { serve(by: deadline, reply) { .holdButtons(buttons) } }
    func move(x: Int8, y: Int8, by deadline: UInt64, reply: @escaping (Error?) -> Void) { serve(by: deadline, reply) { try .move(x: x, y: y) } }
    func scroll(vertical: Int8, horizontal: Int8, by deadline: UInt64, reply: @escaping (Error?) -> Void) {
        serve(by: deadline, reply) { try .scroll(vertical: vertical, horizontal: horizontal) }
    }

    /// Answered only once the devices are free, which is the whole point of asking, and
    /// with the release's failure when it had one.
    func leave(reply: @escaping (Error?) -> Void) {
        let released = end(because: "a client left")
        reply(released.flatMap { $0.failed ? refusal(LeftHeld(released: $0)) : nil })
    }

    /// Ends this seat: no act after this is served, and the devices, if this seat holds
    /// them, are released and then freed for the next client. Answers how the release
    /// ended, or nil when this seat held nothing that is still there to release.
    @discardableResult
    func end(because reason: String) -> Released? {
        let heldOn = state.withLock { state in
            state.ended = true
            return state.heldOn
        }
        guard let heldOn else { return nil }
        // Devices lost since hold nothing this seat set down: only the hold is let go.
        guard let up = readiness.up, up.attempt == heldOn else {
            holder.free(connection, on: heldOn)
            return nil
        }
        return up.devices.release(because: reason, when: { holder.holds(connection, on: heldOn) }, then: { holder.free(connection, on: heldOn) })
    }

    /// The connection was interrupted: whatever it held is released, and the devices stay
    /// its own, since an interrupted connection may yet be used again.
    func interrupted() {
        guard let heldOn = state.withLock({ $0.heldOn }), let up = readiness.up, up.attempt == heldOn else { return }
        _ = up.devices.release(because: "a client was interrupted", when: { holder.holds(connection, on: heldOn) }, then: {})
    }

    /// Who holds the devices, read and not claimed, or why they are not up.
    func holding(reply: @escaping (NSNumber?, Bool, Error?) -> Void) {
        do {
            let up = try readiness.devices()
            let pid = holder.pid(on: up.attempt)
            reply(pid.map { NSNumber(value: $0) }, pid == nil && up.devices.leftHeld, nil)
        } catch {
            reply(nil, false, refusal(error))
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

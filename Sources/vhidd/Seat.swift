import Foundation
import Helper
import Keystrokes
import Pointing
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
/// arrived: its wait for this seat's turn and for the devices', a reading of the driver
/// when they are down, and its report are all counted, and an act whose turn comes too
/// late is refused, as `Late`, while the client is still there to hear it. Nothing is done
/// on the devices for a client already told its act failed. A read - the cursor, the
/// displays - has the same limit, counted the same way.
final class Seat: NSObject, HelperService, @unchecked Sendable {
    /// How long an act has, from when it arrives.
    static let actLimit = HelperConnection.replyTimeout - .seconds(1)

    private let connection: ObjectIdentifier
    private let pid: pid_t
    private let holder: Holder
    private let readiness: Readiness
    private let screen: any ScreenSource
    private let timeline: Timeline
    /// Where this seat stands, under `seat` across each act, so an act cannot pass the
    /// check and then claim after `end` has freed the devices.
    private let seat = TimedLock()
    private var state = State.unclaimed

    /// [LAW:types-are-the-program] A seat has acted on the devices of one attempt, or not
    /// yet, or has ended. Devices lost and brought up again hold nothing this client set
    /// down, so a seat holding the lost ones ends rather than carrying on as if its keys
    /// were still down. [LAW:no-silent-failure]
    private enum State {
        case unclaimed
        case holding(attempt: Int)
        case ended
    }

    init(_ connection: ObjectIdentifier, pid: pid_t, holder: Holder, readiness: Readiness, screen: any ScreenSource, timeline: Timeline) {
        self.connection = connection
        self.screen = screen
        self.pid = pid
        self.holder = holder
        self.readiness = readiness
        self.timeline = timeline
    }

    /// [LAW:dataflow-not-control-flow] Every act is the same act: what it asks for, read
    /// off the wire before anything is claimed; the devices, claimed for this seat if they
    /// are up and nobody holds them; the act on them by its deadline; and the answer, nil
    /// or the refusal. Up is asked first, so a client turned away while they are down
    /// holds nothing and the next is told why too, not that the first one is in the way.
    ///
    /// [LAW:nothing-unseen] An act refused or missed is told here, at its one way out, with
    /// whose it was and what it cost; an act done is not, since one line for every key a
    /// client types would be a log of its typing.
    private func serve(_ verb: String, _ reply: @escaping (Error?) -> Void, _ parse: () throws -> (any ServedDevices, Deadline) throws -> Void) {
        // Made before anything waits, so every wait below is counted against it.
        let deadline = timeline.deadline(within: Self.actLimit)
        do {
            let act = try parse()
            try seat.withLock(by: deadline) {
                if case .ended = state { throw Ended() }
                let up = try readiness.devices(by: deadline)
                if case .holding(let attempt) = state, attempt != up.attempt {
                    // The lost attempt's devices hold nothing, so the claim on them is
                    // freed with nothing to release: left standing, this seat's ending
                    // would release devices that are gone, and say it failed.
                    state = .ended
                    holder.free(connection) { _ in .released }
                    throw Lost()
                }
                try holder.claim(connection, by: pid, on: up, by: deadline)
                state = .holding(attempt: up.attempt)
                try act(up.devices, deadline)
            }
            reply(nil)
        } catch {
            log("pid \(pid)'s \(verb) was refused after \(deadline.spent): \(error)")
            reply(refusal(error))
        }
    }

    func down(usage: UInt16, reply: @escaping (Error?) -> Void) {
        serve("down", reply) { let usage = try Self.usage(usage); return { try $0.down(usage, by: $1) } }
    }
    func releaseAll(reply: @escaping (Error?) -> Void) { serve("releaseAll", reply) { { try $0.releaseAll(by: $1) } } }
    /// [LAW:single-enforcer] More than a report carries is refused by `HeldKeys`, by name,
    /// before the device sees it. A usage named twice on the wire is one key held.
    func hold(usages: [UInt16], reply: @escaping (Error?) -> Void) {
        serve("hold", reply) { let keys = try HeldKeys(Set(usages.map(Self.usage))); return { try $0.hold(keys, by: $1) } }
    }
    func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) {
        serve("buttonDown", reply) { let button = try Self.button(button); return { try $0.buttonDown(button, by: $1) } }
    }
    func releaseButtons(reply: @escaping (Error?) -> Void) { serve("releaseButtons", reply) { { try $0.releaseButtons(by: $1) } } }
    func holdButtons(_ buttons: UInt32, reply: @escaping (Error?) -> Void) {
        serve("holdButtons", reply) { let buttons = Button.buttons(in: buttons); return { try $0.holdButtons(buttons, by: $1) } }
    }
    func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) {
        serve("move", reply) { let delta = Move(x: try Self.count(x), y: try Self.count(y)); return { try $0.move(delta, by: $1) } }
    }
    func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) {
        serve("scroll", reply) { let delta = Scroll(vertical: try Self.count(vertical), horizontal: try Self.count(horizontal)); return { try $0.scroll(delta, by: $1) } }
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
            state = .ended
            holder.free(connection) { $0.releaseEverything(because: reason) }
        }
    }

    /// The connection was interrupted: what this seat holds is released, and the seat
    /// keeps the devices, under the seat's lock as an ending is, so the release is of this
    /// seat's own devices and is not made part way through its act.
    ///
    /// A release that fails is told where it failed, and the seat keeps the devices all
    /// the same: its client's next report is built from the nothing this release asked
    /// for, and its leaving releases again.
    func interrupted() {
        seat.withLock {
            holder.whileHolding(connection) { _ = $0.releaseEverything(because: "a client was interrupted") }
        }
    }

    /// Who holds the devices, read and not claimed, or why they are not up.
    func status(reply: @escaping (NSNumber?, Error?) -> Void) {
        do {
            let up = try readiness.devices(by: timeline.deadline(within: Self.actLimit))
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
            let at = try screen.cursor(by: timeline.deadline(within: Self.actLimit))
            reply(at.x, at.y, nil)
        } catch {
            reply(0, 0, refusal(error))
        }
    }

    /// The display layout in the session in front, as its record. Claims nothing, like
    /// `cursor`.
    func layout(reply: @escaping ([NSNumber], Error?) -> Void) {
        do {
            reply(try screen.layout(by: timeline.deadline(within: Self.actLimit)).record.map { NSNumber(value: $0) }, nil)
        } catch {
            reply([], refusal(error))
        }
    }

    /// A call on a seat whose devices were lost under it.
    struct Lost: Error, CustomStringConvertible {
        var description: String { "the devices this connection held were lost and brought up again, and nothing it held is held on the new ones; connect again" }
    }

    /// A call on a seat that has ended.
    struct Ended: Error, CustomStringConvertible {
        var description: String { "this connection has already handed the devices back" }
    }

    /// [LAW:parse-dont-validate] The wire is wider than the device on every count - a usage
    /// outside the keyboard page's keys names no key, button 0 and 33 upward have no bit,
    /// and -128 is below the descriptor's minimum - and a value the device cannot carry is
    /// refused here, where the wire is read, by name, once, rather than folded to the
    /// nearest one it can.
    private static func usage(_ value: UInt16) throws -> Usage {
        guard Usage.keys.contains(value) else { throw NotOnTheDevice.usage(value) }
        return Usage(rawValue: value)
    }

    private static func button(_ number: UInt8) throws -> Button {
        guard let button = Button(rawValue: number) else { throw NotOnTheDevice.button(number) }
        return button
    }

    private static func count(_ value: Int8) throws -> Count {
        guard let count = Count(exactly: value) else { throw NotOnTheDevice.count(value) }
        return count
    }
}

/// A value the wire can carry and the device cannot.
enum NotOnTheDevice: Error, CustomStringConvertible {
    case usage(UInt16)
    case button(UInt8)
    case count(Int8)

    var description: String {
        switch self {
        case .usage(let value): "usage \(value) is not one of the keys \(Usage.keys.lowerBound) through \(Usage.keys.upperBound)"
        case .button(let number): "button \(number) is not one of the 32 the device has a bit for"
        case .count(let value): "\(value) is outside the -127 through 127 a report carries"
        }
    }
}

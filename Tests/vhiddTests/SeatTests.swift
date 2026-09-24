import Foundation
import Testing
@testable import vhidd

/// A seat that has ended - its client left, or its connection went - serves nothing and
/// claims nothing, whichever way it ended. [LAW:behavior-not-structure]
@Suite struct SeatTests {
    private final class Devices: NSObject, ServedDevices, @unchecked Sendable {
        private let lock = NSLock()
        private var acts: [String] = []
        var done: [String] { lock.lock(); defer { lock.unlock() }; return acts }
        private func note(_ act: String, _ reply: (Error?) -> Void) { lock.lock(); acts.append(act); lock.unlock(); reply(nil) }
        func down(usage: UInt16, reply: @escaping (Error?) -> Void) { note("down \(usage)", reply) }
        func releaseAll(reply: @escaping (Error?) -> Void) { note("release keys", reply) }
        func buttonDown(_ button: UInt8, reply: @escaping (Error?) -> Void) { note("button \(button)", reply) }
        func releaseButtons(reply: @escaping (Error?) -> Void) { note("release buttons", reply) }
        func move(x: Int8, y: Int8, reply: @escaping (Error?) -> Void) { note("move", reply) }
        func scroll(vertical: Int8, horizontal: Int8, reply: @escaping (Error?) -> Void) { note("scroll", reply) }
        func releaseEverything(because reason: String) { lock.lock(); acts.append(reason); lock.unlock() }
    }

    private let one = NSObject()

    /// The crash the ending exists for: the client's connection goes while an act of its
    /// is still on its way, and the act arrives after. It must not take the devices for a
    /// connection nobody is left to free.
    @Test func anActArrivingAfterTheConnectionWentTakesNothing() {
        let (holder, devices) = (Holder(), Devices())
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: holder, devices: devices)
        seat.down(usage: 4) { #expect($0 == nil) }
        seat.end(because: "a client went away")
        var refusal: Error?
        seat.down(usage: 5) { refusal = $0 }
        #expect((refusal as NSError?)?.localizedDescription == "\(Seat.Ended())")
        #expect(holder.pid == nil)
        #expect(devices.done == ["down 4", "a client went away"])
    }

    /// A seat that ends without ever acting releases nothing: it never held the devices.
    @Test func aSeatThatNeverActedReleasesNothingWhenItEnds() {
        let (holder, devices) = (Holder(), Devices())
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: holder, devices: devices)
        seat.end(because: "a client went away")
        #expect(devices.done.isEmpty)
        #expect(holder.pid == nil)
    }
}

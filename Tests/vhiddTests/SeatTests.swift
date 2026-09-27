import Foundation
import Testing
@testable import vhidd

/// A seat that has ended - its client left, or its connection went - serves nothing and
/// claims nothing, whichever way it ended. [LAW:behavior-not-structure]
@Suite struct SeatTests {

    private let one = NSObject()

    /// The crash the ending exists for: the client's connection goes while an act of its
    /// is still on its way, and the act arrives after. It must not take the devices for a
    /// connection nobody is left to free.
    @Test func anActArrivingAfterTheConnectionWentTakesNothing() {
        let (holder, devices) = (Holder(), RecordingDevices())
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: holder, readiness: .serving(devices))
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
        let (holder, devices) = (Holder(), RecordingDevices())
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: holder, readiness: .serving(devices))
        seat.end(because: "a client went away")
        #expect(devices.done.isEmpty)
        #expect(holder.pid == nil)
    }

    /// While the devices are down an act is refused with why, and claims nothing: the next
    /// client is told the same reason, not that the first is in the way.
    @Test func anActWhileTheDevicesAreDownIsRefusedWithWhyAndClaimsNothing() {
        let (holder, readiness) = (Holder(), Readiness())
        let other = NSObject()
        let first = Seat(ObjectIdentifier(one), pid: 41, holder: holder, readiness: readiness)
        let second = Seat(ObjectIdentifier(other), pid: 42, holder: holder, readiness: readiness)
        var refusals: [String?] = []
        first.down(usage: 4) { refusals.append(($0 as NSError?)?.localizedDescription) }
        second.down(usage: 4) { refusals.append(($0 as NSError?)?.localizedDescription) }
        #expect(refusals == Array(repeating: "\(Readiness.Down.starting)", count: 2))
        #expect(holder.pid == nil)
    }

    /// Status is not the proof the devices are up when they are not: it answers why.
    @Test func statusWhileTheDevicesAreDownSaysWhy() {
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: Holder(), readiness: Readiness())
        var answer: (NSNumber?, String?)
        seat.status { answer = ($0, ($1 as NSError?)?.localizedDescription) }
        #expect(answer.0 == nil)
        #expect(answer.1 == "\(Readiness.Down.starting)")
    }
}

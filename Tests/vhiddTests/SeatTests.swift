import DriverExtension
import Foundation
import Installations
import TestClock
import Testing
import Time
@testable import vhidd

/// A seat that has ended - its client left, or its connection went - serves nothing and
/// acquires nothing, whichever way it ended. [LAW:behavior-not-structure]
@Suite struct SeatTests {

    private let one = NSObject()
    private let clock = ManualClock()

    /// The instant a request's client stops waiting, as the wire carries it: never reached,
    /// since nothing here moves the clock.
    private var by: UInt64 { Deadline.within(.seconds(5), on: Clock(clock)).at.nanoseconds }

    private func seat(_ connection: NSObject? = nil, pid: pid_t = 41, holder: Holder = Holder(), readiness: Readiness) -> Seat {
        Seat(ObjectIdentifier(connection ?? one), pid: pid, holder: holder, readiness: readiness, screen: FixedScreen(), clock: Clock(clock))
    }

    /// The crash the ending exists for: the client's connection goes while a request of its
    /// is still on its way, and the request arrives after. It must not take the devices for a
    /// connection nobody is left to free.
    @Test func aRequestArrivingAfterTheConnectionWentAcquiresNothing() {
        let (holder, devices) = (Holder(), RecordingDevices())
        let seat = seat(holder: holder, readiness: .serving(devices))
        seat.down(usage: 4, by: by) { #expect($0 == nil) }
        seat.end(because: "a client went away")
        var refusal: Error?
        seat.down(usage: 5, by: by) { refusal = $0 }
        #expect((refusal as NSError?)?.localizedDescription == "\(Seat.Ended())")
        #expect(holder.pid(on: 1) == nil)
        #expect(devices.done == ["down 4", "a client went away"])
    }

    /// A seat that ends without ever sending a command releases nothing: it never held the
    /// devices.
    @Test func aSeatThatNeverSentACommandReleasesNothingWhenItEnds() {
        let (holder, devices) = (Holder(), RecordingDevices())
        let seat = seat(holder: holder, readiness: .serving(devices))
        #expect(seat.end(because: "a client went away") == nil)
        #expect(devices.done.isEmpty)
        #expect(holder.pid(on: 1) == nil)
    }

    /// A seat refused as busy holds nothing, so its ending releases nothing of the holder's.
    @Test func aRefusedSeatsEndingReleasesNothingOfTheHolders() {
        let (holder, devices, other) = (Holder(), RecordingDevices(), NSObject())
        let readiness = Readiness.serving(devices)
        let first = seat(holder: holder, readiness: readiness)
        let second = seat(other, pid: 42, holder: holder, readiness: readiness)
        first.down(usage: 4, by: by) { #expect($0 == nil) }
        var refused: NSError?
        second.down(usage: 5, by: by) { refused = $0 as NSError? }
        #expect(refused?.code == Installation.seatRefusedCode)
        second.end(because: "a client went away")
        #expect(devices.done == ["down 4"])
        #expect(holder.pid(on: 1) == 41)
    }

    /// While the devices are down a request is refused with why, and acquires nothing: the next
    /// client is told the same reason, not that the first is in the way.
    @Test func aRequestWhileTheDevicesAreDownIsRefusedWithWhyAndAcquiresNothing() {
        let (holder, readiness) = (Holder(), Readiness(driver: { .running }))
        let other = NSObject()
        let first = seat(holder: holder, readiness: readiness)
        let second = seat(other, pid: 42, holder: holder, readiness: readiness)
        var refusals: [String?] = []
        first.down(usage: 4, by: by) { refusals.append(($0 as NSError?)?.localizedDescription) }
        second.down(usage: 4, by: by) { refusals.append(($0 as NSError?)?.localizedDescription) }
        #expect(refusals == Array(repeating: "\(Readiness.Down.starting)", count: 2))
        #expect(holder.pid(on: 1) == nil)
    }

    /// A command whose values the devices cannot take is refused as it is parsed, before any
    /// lock, and acquires nothing: the next client is not refused over it.
    @Test func aCommandTheDevicesCannotTakeAcquiresNothing() {
        let (holder, devices) = (Holder(), RecordingDevices())
        let seat = seat(holder: holder, readiness: .serving(devices))
        var refused: NSError?
        seat.buttonDown(0, by: by) { refused = $0 as NSError? }
        // A refusal with no code of its own: nothing was sent.
        #expect(refused?.code == 1)
        #expect(holder.pid(on: 1) == nil)
        #expect(devices.done.isEmpty)
    }

    /// The refusal a client receives names the driver's step, under the code that says
    /// the devices are down.
    @Test func aRequestRefusedWhileTheDriverIsOffCarriesItsStep() throws {
        let seat = seat(readiness: Readiness(driver: { .awaitingApproval }))
        var refused: NSError?
        seat.down(usage: 4, by: by) { refused = $0 as NSError? }
        let step = try #require(DriverState.awaitingApproval.step)
        #expect(refused?.localizedDescription == "\(Readiness.Down.starting)\nThe driver extension reads \(DriverState.awaitingApproval.rawValue):\n\(step)")
        #expect(refused?.code == Installation.devicesDownCode)
    }

    /// Asking who holds the devices is not the proof they are up when they are not: it
    /// answers why.
    @Test func holdingWhileTheDevicesAreDownSaysWhy() {
        let seat = seat(readiness: Readiness(driver: { .running }))
        var answer: (NSNumber?, Bool, String?) = (nil, false, nil)
        seat.holding { answer = ($0, $1, ($2 as NSError?)?.localizedDescription) }
        #expect(answer.0 == nil)
        #expect(!answer.1)
        #expect(answer.2 == "\(Readiness.Down.starting)")
    }

    /// A client whose release failed is told so when it leaves, and the devices it left
    /// read as stuck - not free - until a release lands.
    @Test func aLeaveWhoseReleaseFailedSaysSoAndLeavesTheDevicesHeld() {
        let failed = Released(keyboard: "the driver did not answer", mouse: nil)
        let (holder, devices) = (Holder(), RecordingDevices(releasing: failed))
        let seat = seat(holder: holder, readiness: .serving(devices))
        seat.down(usage: 4, by: by) { #expect($0 == nil) }
        var refused: NSError?
        seat.leave { refused = $0 as NSError? }
        #expect(refused?.localizedDescription == "\(Stuck(released: failed))")
        #expect(holder.pid(on: 1) == nil)
        var answer: (NSNumber?, Bool)?
        seat.holding { pid, stuck, _ in answer = (pid, stuck) }
        #expect(answer?.0 == nil)
        #expect(answer?.1 == true)
    }

    /// A client whose devices were lost is told so on its next request, and on every request
    /// after, rather than sending to fresh devices as if what it held were still held.
    @Test func aSeatWhoseDevicesWereLostEnds() {
        let (holder, readiness) = (Holder(), Readiness(driver: { .running }))
        let first = readiness.begin()
        readiness.up(RecordingDevices())
        let seat = seat(holder: holder, readiness: readiness)
        seat.down(usage: 225, by: by) { #expect($0 == nil) }
        _ = readiness.lost(NSError(domain: "test", code: 1), in: first)
        _ = readiness.begin()
        let fresh = RecordingDevices()
        readiness.up(fresh)
        var refusals: [String?] = []
        seat.down(usage: 4, by: by) { refusals.append(($0 as NSError?)?.localizedDescription) }
        seat.down(usage: 4, by: by) { refusals.append(($0 as NSError?)?.localizedDescription) }
        #expect(refusals == ["\(Seat.Lost())", "\(Seat.Ended())"])
        #expect(fresh.done.isEmpty)
        #expect(holder.pid(on: 1) == nil)
    }
}

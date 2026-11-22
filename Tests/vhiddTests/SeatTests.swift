import DriverExtension
import Foundation
import Helper
import Installations
import Testing
import Waiting
@testable import vhidd

/// A seat that has ended - its client left, or its connection went - serves nothing and
/// claims nothing, whichever way it ended. [LAW:behavior-not-structure]
@Suite(.hangGuarded) struct SeatTests {

    private let one = NSObject()

    /// The crash the ending exists for: the client's connection goes while an act of its
    /// is still on its way, and the act arrives after. It must not take the devices for a
    /// connection nobody is left to free.
    @Test func anActArrivingAfterTheConnectionWentTakesNothing() {
        let (holder, devices) = (Holder(), RecordingDevices())
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: holder, readiness: .serving(devices), screen: FixedScreen(), timeline: .suspending)
        seat.down(usage: 4) { #expect($0 == nil) }
        seat.end(because: "a client went away")
        var refusal: Error?
        seat.down(usage: 5) { refusal = $0 }
        #expect((refusal as NSError?)?.localizedDescription == "\(Seat.Ended())")
        #expect(holder.pid(on: 1) == nil)
        #expect(devices.done == ["down 4", "a client went away"])
    }

    /// An act whose turn has not come by its limit - the act before it still under way -
    /// is refused before it reaches the devices, while its client is still listening: the
    /// client is told nothing of it was sent, and the devices never see it, not even once
    /// the act ahead has finished. The act ahead is held for as long as the test likes,
    /// so the limit is spent whatever the runner's pace.
    @Test func anActWhoseTurnDoesNotComeInTimeIsRefusedAndNeverReachesTheDevices() throws {
        let devices = RecordingDevices(holdingActs: true)
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: Holder(), readiness: .serving(devices), screen: FixedScreen(), timeline: .suspending)
        let first = Latch<Error??>(nil)
        Thread.detachNewThread { seat.down(usage: 4) { answer in first.update { $0 = answer } } }
        try devices.awaitBegun("down 4")
        var refused: NSError?
        seat.down(usage: 5) { refused = $0 as NSError? }
        #expect(refused?.localizedDescription == "\(Late(limit: Seat.actLimit))")
        #expect(refused?.code == 1)
        devices.turn.update { $0 = true }
        #expect(try first.wait(for: "the first act's answer") { $0 } == nil)
        #expect(devices.done == ["down 4"])
    }

    /// The act's limit is counted from when it arrives and ends before its client stops
    /// listening, with room for the refusal to reach it.
    @Test func anActIsGivenUpOnBeforeItsClientStopsListening() {
        #expect(Seat.actLimit < HelperConnection.replyTimeout)
        #expect(Seat.actLimit > .zero)
    }

    /// A seat that ends without ever acting releases nothing: it never held the devices.
    @Test func aSeatThatNeverActedReleasesNothingWhenItEnds() {
        let (holder, devices) = (Holder(), RecordingDevices())
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: holder, readiness: .serving(devices), screen: FixedScreen(), timeline: .suspending)
        seat.end(because: "a client went away")
        #expect(devices.done.isEmpty)
        #expect(holder.pid(on: 1) == nil)
    }

    /// While the devices are down an act is refused with why, and claims nothing: the next
    /// client is told the same reason, not that the first is in the way.
    @Test func anActWhileTheDevicesAreDownIsRefusedWithWhyAndClaimsNothing() {
        let (holder, readiness) = (Holder(), Readiness(driver: { .running }))
        let other = NSObject()
        let first = Seat(ObjectIdentifier(one), pid: 41, holder: holder, readiness: readiness, screen: FixedScreen(), timeline: .suspending)
        let second = Seat(ObjectIdentifier(other), pid: 42, holder: holder, readiness: readiness, screen: FixedScreen(), timeline: .suspending)
        var refusals: [String?] = []
        first.down(usage: 4) { refusals.append(($0 as NSError?)?.localizedDescription) }
        second.down(usage: 4) { refusals.append(($0 as NSError?)?.localizedDescription) }
        #expect(refusals == Array(repeating: "\(Readiness.Down.starting)", count: 2))
        #expect(holder.pid(on: 1) == nil)
    }

    /// The refusal a client receives names the driver's step, under the code that says
    /// the devices are down.
    @Test func anActRefusedWhileTheDriverIsOffCarriesItsStep() throws {
        let readiness = Readiness(driver: { .awaitingApproval })
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: Holder(), readiness: readiness, screen: FixedScreen(), timeline: .suspending)
        var refused: NSError?
        seat.down(usage: 4) { refused = $0 as NSError? }
        let step = try #require(DriverState.awaitingApproval.step)
        #expect(refused?.localizedDescription == "\(Readiness.Down.starting)\nThe driver extension reads \(DriverState.awaitingApproval.rawValue):\n\(step)")
        #expect(refused?.code == Installation.devicesDownCode)
    }

    /// Status is not the proof the devices are up when they are not: it answers why.
    @Test func statusWhileTheDevicesAreDownSaysWhy() {
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: Holder(), readiness: Readiness(driver: { .running }), screen: FixedScreen(), timeline: .suspending)
        var answer: (NSNumber?, String?)
        seat.status { answer = ($0, ($1 as NSError?)?.localizedDescription) }
        #expect(answer.0 == nil)
        #expect(answer.1 == "\(Readiness.Down.starting)")
    }

    /// A client whose devices were lost is told so on its next act, and on every act
    /// after, rather than acting on fresh devices as if what it held were still held.
    @Test func aSeatWhoseDevicesWereLostEnds() {
        let (holder, readiness) = (Holder(), Readiness(driver: { .running }))
        let first = readiness.begin()
        readiness.up(RecordingDevices())
        let seat = Seat(ObjectIdentifier(one), pid: 41, holder: holder, readiness: readiness, screen: FixedScreen(), timeline: .suspending)
        seat.down(usage: 225) { #expect($0 == nil) }
        _ = readiness.lost(NSError(domain: "test", code: 1), in: first)
        _ = readiness.begin()
        let fresh = RecordingDevices()
        readiness.up(fresh)
        var refusals: [String?] = []
        seat.down(usage: 4) { refusals.append(($0 as NSError?)?.localizedDescription) }
        seat.down(usage: 4) { refusals.append(($0 as NSError?)?.localizedDescription) }
        #expect(refusals == ["\(Seat.Lost())", "\(Seat.Ended())"])
        #expect(fresh.done.isEmpty)
        #expect(holder.pid(on: 1) == nil)
    }
}

import Foundation
import Installations
import OwnThread
import Testing
import Waiting
@testable import vhidd

/// One client at a time holds the devices, and the refusal names who has them.
/// [LAW:behavior-not-structure]
@Suite(.hangGuarded, .ownThread) struct HolderTests {
    /// Held for the test's life: an identifier taken from an object that is gone names
    /// whatever is allocated at its address next, which was the other one.
    private let one = NSObject(), other = NSObject()
    private var first: ObjectIdentifier { ObjectIdentifier(one) }
    private var second: ObjectIdentifier { ObjectIdentifier(other) }

    /// The devices one attempt brought up.
    private static func up(_ attempt: Int, _ devices: RecordingDevices = RecordingDevices()) -> Readiness.Up {
        Readiness.Up(devices: devices, attempt: attempt)
    }

    /// The first act claims the devices; a second client's claim is refused naming the
    /// holder, and the holder's next act is served on the claim it has.
    @Test func aSecondClientsClaimIsRefusedNamingTheHolder() throws {
        let holder = Holder()
        let up = Self.up(1)
        #expect(holder.pid(on: 1) == nil)
        try holder.claim(first, by: 41, on: up, by: guarded())
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42, on: up, by: guarded()) }
        #expect(refusal?.pid == 41)
        try holder.claim(first, by: 41, on: up, by: guarded())
        #expect(holder.pid(on: 1) == 41)
    }

    @Test func freeingRunsTheReleaseOnTheHoldersDevicesAndFreesThemForTheNextClaim() throws {
        let holder = Holder()
        let devices = RecordingDevices()
        try holder.claim(first, by: 41, on: Self.up(1, devices), by: guarded())
        holder.free(first) { $0.releaseEverything(because: "left") }
        #expect(devices.done == ["left"])
        try holder.claim(second, by: 42, on: Self.up(1), by: guarded())
    }

    /// The release a leaving client is owed runs outside the holder's lock, and the claim
    /// is still the leaver's while it runs: the next client is told at once whose the
    /// devices are, and is not handed them until the release is over.
    @Test func aClaimDuringTheLeaversReleaseIsRefusedAtOnceAndServedAfterIt() throws {
        let holder = Holder()
        let up = Self.up(1)
        try holder.claim(first, by: 41, on: up, by: guarded())
        let releasing = Latch(false), released = Latch(false), go = Latch(false)
        Thread.detachNewThread { [first] in
            holder.free(first) { _ in
                releasing.update { $0 = true }
                _ = try? go.wait(for: "the test to end the release") { $0 }
                return .released
            }
            released.update { $0 = true }
        }
        try releasing.wait(for: "the release to begin") { $0 }
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42, on: up, by: guarded()) }
        #expect(refusal?.pid == 41)
        go.update { $0 = true }
        try released.wait(for: "the release to end") { $0 }
        try holder.claim(second, by: 42, on: up, by: guarded())
    }

    /// A refused connection never held the devices, and a connection that left no longer
    /// does. Either one ending must neither free the devices from under the holder nor
    /// release the holder's keys and buttons.
    @Test func freeingByOneThatDoesNotHoldItChangesNothingAndReleasesNothing() throws {
        let holder = Holder()
        let up = Self.up(1)
        try holder.claim(first, by: 41, on: up, by: guarded())
        var released = false
        holder.free(second) { _ in released = true; return .released }
        #expect(!released)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42, on: up, by: guarded()) }
        #expect(refusal?.pid == 41)
    }

    @Test func onlyTheHolderIsServed() throws {
        let holder = Holder()
        try holder.claim(first, by: 41, on: Self.up(1), by: guarded())
        var served: [String] = []
        holder.whileHolding(first) { _ in served.append("first") }
        holder.whileHolding(second) { _ in served.append("second") }
        #expect(served == ["first"])
    }

    /// What a refused client reads is the refusal as the reply carries it, so that is
    /// what is pinned: it names the devices, both of them, whichever its verbs use.
    @Test func aClientRefusedAsBusyReadsThatAPidHoldsTheDevices() {
        #expect(refusal(Holder.Busy(pid: 41)).localizedDescription == "pid 41 holds the devices")
    }

    /// A hold on devices an earlier attempt brought up is no hold: they are gone, so the
    /// next client is not refused over them, and the earlier holder's ending neither
    /// frees nor releases the devices the next client claimed.
    @Test func aHoldOnLostDevicesDoesNotRefuseTheNextClient() throws {
        let holder = Holder()
        let (lost, fresh) = (RecordingDevices(), RecordingDevices())
        try holder.claim(first, by: 41, on: Self.up(1, lost), by: guarded())
        try holder.claim(second, by: 42, on: Self.up(2, fresh), by: guarded())
        #expect(holder.pid(on: 2) == 42)
        #expect(holder.pid(on: 3) == nil)
        holder.free(first) { $0.releaseEverything(because: "left") }
        #expect(fresh.done.isEmpty)
        #expect(holder.pid(on: 2) == 42)
    }

    /// A leaver whose release failed leaves the devices to nobody: the next client's first
    /// act releases them again by its own deadline, under its own claim, before it acts.
    @Test func devicesWhoseReleaseFailedAreReleasedAgainBeforeTheNextClientActs() throws {
        let holder = Holder()
        let devices = RecordingDevices()
        let up = Self.up(1, devices)
        try holder.claim(first, by: 41, on: up, by: guarded())
        devices.unreleased = Unreleased(reason: "left", keyboard: DevicesTests.Refused(), mouse: nil)
        holder.free(first) { $0.releaseEverything(because: "left") }
        #expect(holder.pid(on: 1) == nil)
        devices.unreleased = nil
        try holder.claim(second, by: 42, on: up, by: guarded())
        #expect(devices.done == ["left", "release"])
        #expect(holder.pid(on: 1) == 42)
    }

    /// When that release fails too, the client is refused as holding nothing - nothing of
    /// its act was sent - and the devices stay unreleased for the next to try.
    @Test func aClientWhoseReleaseOfTheLastOnesKeysFailsIsRefusedAndHoldsNothing() throws {
        let holder = Holder()
        let devices = RecordingDevices()
        let up = Self.up(1, devices)
        try holder.claim(first, by: 41, on: up, by: guarded())
        devices.unreleased = Unreleased(reason: "left", keyboard: DevicesTests.Refused(), mouse: nil)
        holder.free(first) { $0.releaseEverything(because: "left") }
        #expect(throws: Holder.LeftHeld.self) { try holder.claim(second, by: 42, on: up, by: guarded()) }
        #expect(holder.pid(on: 1) == nil)
        #expect(refusal(Holder.LeftHeld(left: devices.unreleased!, release: DevicesTests.Refused())).code == Installation.seatRefusedCode)
        devices.unreleased = nil
        try holder.claim(second, by: 42, on: up, by: guarded())
        #expect(devices.done == ["left", "release", "release"])
    }
}

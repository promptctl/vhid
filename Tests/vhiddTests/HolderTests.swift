import Foundation
import Testing
import Waiting
@testable import vhidd

/// One client at a time holds the devices, and the refusal names who has them.
/// [LAW:behavior-not-structure]
@Suite(.hangGuarded) struct HolderTests {
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
        try holder.claim(first, by: 41, on: up)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42, on: up) }
        #expect(refusal?.pid == 41)
        try holder.claim(first, by: 41, on: up)
        #expect(holder.pid(on: 1) == 41)
    }

    @Test func freeingRunsTheReleaseOnTheHoldersDevicesAndFreesThemForTheNextClaim() throws {
        let holder = Holder()
        let devices = RecordingDevices()
        try holder.claim(first, by: 41, on: Self.up(1, devices))
        holder.free(first) { $0.releaseEverything(because: "left") }
        #expect(devices.done == ["left"])
        try holder.claim(second, by: 42, on: Self.up(1))
    }

    /// The release a leaving client is owed runs outside the holder's lock, and the claim
    /// is still the leaver's while it runs: the next client is told at once whose the
    /// devices are, and is not handed them until the release is over.
    @Test func aClaimDuringTheLeaversReleaseIsRefusedAtOnceAndServedAfterIt() throws {
        let holder = Holder()
        let up = Self.up(1)
        try holder.claim(first, by: 41, on: up)
        let releasing = Latch(false), released = Latch(false), go = Latch(false)
        Thread.detachNewThread { [first] in
            holder.free(first) { _ in
                releasing.update { $0 = true }
                _ = try? go.wait(for: "the test to end the release") { $0 }
            }
            released.update { $0 = true }
        }
        try releasing.wait(for: "the release to begin") { $0 }
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42, on: up) }
        #expect(refusal?.pid == 41)
        go.update { $0 = true }
        try released.wait(for: "the release to end") { $0 }
        try holder.claim(second, by: 42, on: up)
    }

    /// A refused connection never held the devices, and a connection that left no longer
    /// does. Either one ending must neither free the devices from under the holder nor
    /// release the holder's keys and buttons.
    @Test func freeingByOneThatDoesNotHoldItChangesNothingAndReleasesNothing() throws {
        let holder = Holder()
        let up = Self.up(1)
        try holder.claim(first, by: 41, on: up)
        var released = false
        holder.free(second) { _ in released = true }
        #expect(!released)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42, on: up) }
        #expect(refusal?.pid == 41)
    }

    @Test func onlyTheHolderIsServed() throws {
        let holder = Holder()
        try holder.claim(first, by: 41, on: Self.up(1))
        var served: [String] = []
        #expect(holder.whileHolding(first) { _ in served.append("first") })
        #expect(!holder.whileHolding(second) { _ in served.append("second") })
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
        try holder.claim(first, by: 41, on: Self.up(1, lost))
        try holder.claim(second, by: 42, on: Self.up(2, fresh))
        #expect(holder.pid(on: 2) == 42)
        #expect(holder.pid(on: 3) == nil)
        holder.free(first) { $0.releaseEverything(because: "left") }
        #expect(fresh.done.isEmpty)
        #expect(holder.pid(on: 2) == 42)
    }
}

import Foundation
import Testing
@testable import vhidd

/// One client at a time holds the devices, and the refusal names who has them.
/// [LAW:behavior-not-structure]
@Suite struct HolderTests {
    /// Held for the test's life: an identifier taken from an object that is gone names
    /// whatever is allocated at its address next, which was the other one.
    private let one = NSObject(), other = NSObject()
    private var first: ObjectIdentifier { ObjectIdentifier(one) }
    private var second: ObjectIdentifier { ObjectIdentifier(other) }

    /// The first act claims the devices; a second client's act is refused naming the
    /// holder and never runs, and the holder's next act is served without a new claim.
    @Test func aSecondClientsActIsRefusedNamingTheHolder() throws {
        let holder = Holder()
        #expect(holder.pid == nil)
        var served: [String] = []
        try holder.serve(first, by: 41, on: 1) { served.append("first") }
        let refusal = #expect(throws: Holder.Busy.self) { try holder.serve(second, by: 42, on: 1) { served.append("second") } }
        #expect(refusal?.pid == 41)
        try holder.serve(first, by: 41, on: 1) { served.append("first again") }
        #expect(served == ["first", "first again"])
        #expect(holder.pid == 41)
    }

    @Test func freeingRunsTheReleaseAndFreesTheDevicesForTheNextClaim() throws {
        let holder = Holder()
        try holder.serve(first, by: 41, on: 1) {}
        var released = false
        holder.free(first) { released = true }
        #expect(released)
        try holder.serve(second, by: 42, on: 1) {}
    }

    /// A refused connection never held the devices, and a connection that left no longer
    /// does. Either one ending must neither free the devices from under the holder nor
    /// release the holder's keys and buttons.
    @Test func freeingByOneThatDoesNotHoldItChangesNothingAndReleasesNothing() throws {
        let holder = Holder()
        try holder.serve(first, by: 41, on: 1) {}
        var released = false
        holder.free(second) { released = true }
        #expect(!released)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.serve(second, by: 42, on: 1) {} }
        #expect(refusal?.pid == 41)
    }

    @Test func onlyTheHolderIsServed() throws {
        let holder = Holder()
        try holder.serve(first, by: 41, on: 1) {}
        var served: [String] = []
        #expect(holder.whileHolding(first) { served.append("first") })
        #expect(!holder.whileHolding(second) { served.append("second") })
        #expect(served == ["first"])
    }

    /// What a refused client reads is the refusal as the reply carries it, so that is
    /// what is pinned: it names the devices, both of them, whichever its verbs use.
    @Test func aClientRefusedAsBusyReadsThatAPidHoldsTheDevices() {
        #expect(refusal(Holder.Busy(pid: 41)).localizedDescription == "pid 41 holds the devices")
    }

    /// A hold on devices an earlier attempt brought up is no hold: they are gone, so the
    /// next client is not refused over them.
    @Test func aHoldOnLostDevicesDoesNotRefuseTheNextClient() throws {
        let holder = Holder()
        let (a, b) = (NSObject(), NSObject())
        try holder.serve(ObjectIdentifier(a), by: 41, on: 1) {}
        try holder.serve(ObjectIdentifier(b), by: 42, on: 2) {}
        #expect(holder.pid == 42)
    }
}

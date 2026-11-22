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

    /// The first act claims the devices; a second client's claim is refused naming the
    /// holder, and the holder's next claim is its own again.
    @Test func aSecondClientsClaimIsRefusedNamingTheHolder() throws {
        let holder = Holder()
        #expect(holder.pid(on: 1) == nil)
        try holder.claim(for: first, by: 41, on: 1)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(for: second, by: 42, on: 1) }
        #expect(refusal?.pid == 41)
        try holder.claim(for: first, by: 41, on: 1)
        #expect(holder.pid(on: 1) == 41)
        #expect(holder.holds(first, on: 1))
        #expect(!holder.holds(second, on: 1))
    }

    @Test func freeingFreesTheDevicesForTheNextClaim() throws {
        let holder = Holder()
        try holder.claim(for: first, by: 41, on: 1)
        holder.free(first, on: 1)
        #expect(holder.pid(on: 1) == nil)
        try holder.claim(for: second, by: 42, on: 1)
    }

    /// A refused connection never held the devices, and a connection that left no longer
    /// does: either one ending leaves the holder holding.
    @Test func freeingByOneThatDoesNotHoldThemChangesNothing() throws {
        let holder = Holder()
        try holder.claim(for: first, by: 41, on: 1)
        holder.free(second, on: 1)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(for: second, by: 42, on: 1) }
        #expect(refusal?.pid == 41)
    }

    /// A free is judged against the bring-up it names: the holder of the devices up now is
    /// not freed by a free of the devices an earlier bring-up had.
    @Test func aFreeOfAnEarlierBringUpLeavesTheCurrentHoldAlone() throws {
        let holder = Holder()
        try holder.claim(for: first, by: 41, on: 2)
        holder.free(first, on: 1)
        #expect(holder.pid(on: 2) == 41)
        #expect(holder.holds(first, on: 2))
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
        try holder.claim(for: first, by: 41, on: 1)
        try holder.claim(for: second, by: 42, on: 2)
        #expect(holder.pid(on: 2) == 42)
        #expect(holder.pid(on: 3) == nil)
        #expect(!holder.holds(first, on: 1))
    }
}

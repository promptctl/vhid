import Foundation
import Testing
@testable import vhidd

/// One keyboard, one client at a time, and the refusal names who has it.
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
        try holder.serve(first, by: 41) { served.append("first") }
        let refusal = #expect(throws: Holder.Busy.self) { try holder.serve(second, by: 42) { served.append("second") } }
        #expect(refusal?.pid == 41)
        try holder.serve(first, by: 41) { served.append("first again") }
        #expect(served == ["first", "first again"])
        #expect(holder.pid == 41)
    }

    @Test func freeingRunsTheReleaseAndFreesTheKeyboardForTheNextClaim() throws {
        let holder = Holder()
        try holder.serve(first, by: 41) {}
        var released = false
        holder.free(first) { released = true }
        #expect(released)
        try holder.serve(second, by: 42) {}
    }

    /// A refused connection never held the keyboard, and a connection that left no longer
    /// does. Either one ending must neither free the keyboard from under the holder nor
    /// release the holder's keys.
    @Test func freeingByOneThatDoesNotHoldItChangesNothingAndReleasesNothing() throws {
        let holder = Holder()
        try holder.serve(first, by: 41) {}
        var released = false
        holder.free(second) { released = true }
        #expect(!released)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.serve(second, by: 42) {} }
        #expect(refusal?.pid == 41)
    }

    @Test func onlyTheHolderIsServed() throws {
        let holder = Holder()
        try holder.serve(first, by: 41) {}
        var served: [String] = []
        #expect(holder.whileHolding(first) { served.append("first") })
        #expect(!holder.whileHolding(second) { served.append("second") })
        #expect(served == ["first"])
    }
}

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

    @Test func aSecondClaimIsRefusedNamingTheHolder() throws {
        let holder = Holder()
        try holder.claim(first, by: 41)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42) }
        #expect(refusal?.pid == 41)
    }

    @Test func freeingRunsTheReleaseAndFreesTheKeyboardForTheNextClaim() throws {
        let holder = Holder()
        try holder.claim(first, by: 41)
        var released = false
        holder.free(first) { released = true }
        #expect(released)
        try holder.claim(second, by: 42)
    }

    /// A refused connection never held the keyboard, and a connection that left no longer
    /// does. Either one ending must neither free the keyboard from under the holder nor
    /// release the holder's keys.
    @Test func freeingByOneThatDoesNotHoldItChangesNothingAndReleasesNothing() throws {
        let holder = Holder()
        try holder.claim(first, by: 41)
        var released = false
        holder.free(second) { released = true }
        #expect(!released)
        let refusal = #expect(throws: Holder.Busy.self) { try holder.claim(second, by: 42) }
        #expect(refusal?.pid == 41)
    }

    @Test func onlyTheHolderIsServed() throws {
        let holder = Holder()
        try holder.claim(first, by: 41)
        var served: [String] = []
        #expect(holder.whileHolding(first) { served.append("first") })
        #expect(!holder.whileHolding(second) { served.append("second") })
        #expect(served == ["first"])
    }
}

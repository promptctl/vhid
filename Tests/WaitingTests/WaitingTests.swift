import Foundation
import OwnThread
import Testing
import Waiting

@Suite(.ownThread, .hangLimit) struct LatchTests {
    /// A wait for a condition that already holds returns the state at once.
    @Test func aConditionThatHoldsIsAnsweredAtOnce() throws {
        let latch = Latch(3)
        #expect(try latch.wait(for: "three") { $0 == 3 } == 3)
    }

    /// A waiter is woken by the change that makes its condition hold, with the state that
    /// change left, and not by one that does not.
    @Test func aWaiterIsWokenByTheChangeThatMakesItsConditionHold() async throws {
        let latch = Latch(0)
        let waiting = Latch()
        let seen = Task { try await latch.value(for: "two") { waiting.open(); return $0 == 2 } }
        try await waiting.opened("the waiter to ask")
        latch.update { $0 = 1 }
        latch.update { $0 = 2 }
        #expect(try await seen.value == 2)
    }
}

@Suite(.ownThread, .hangLimit) struct HandshakeTests {
    /// The pid read is the one the child wrote.
    @Test func thePidReadIsTheChildsOwn() throws {
        let handshake = try Handshake()
        defer { handshake.remove() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", handshake.said]
        try child.run()
        #expect(try handshake.pid("the child to start") == child.processIdentifier)
        child.waitUntilExit()
    }
}

import Foundation
import Testing
import OwnThread
import Waiting

@Suite(.ownThread, .hangGuarded) struct LatchTests {
    /// A waiter is handed what its condition found, from a change made on another thread.
    @Test func aWaitEndsOnTheChangeItWasWaitingForAndHandsItBack() throws {
        let latch = Latch<[Int]>([])
        Thread.detachNewThread { latch.update { $0.append(7) } }
        let found = try latch.wait(for: "a number") { $0.first }
        #expect(found == 7)
    }

    @Test func aChangeMadeBeforeTheWaitIsFoundAtOnce() throws {
        let latch = Latch(3)
        try latch.wait(for: "three") { $0 == 3 }
    }
}

@Suite(.ownThread, .hangGuarded) struct HandshakeTests {
    @Test func theLineAChildWritesIsRead() throws {
        let handshake = try Handshake()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "echo hello > \"$0\"", handshake.path]
        try child.run()
        #expect(try handshake.line() == "hello")
        child.waitUntilExit()
    }

    @Test func aHandshakeGoneLeavesNoPipe() throws {
        var handshake: Handshake? = try Handshake()
        let path = try #require(handshake?.path)
        #expect(FileManager.default.fileExists(atPath: path))
        handshake = nil
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}

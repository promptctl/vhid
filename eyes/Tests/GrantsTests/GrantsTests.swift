import Foundation
import Eyes
import Grants
import Testing

struct GrantsTests {
    /// A reading survives the line a reading process prints for it.
    @Test func aReadingRoundTripsThroughItsLine() throws {
        for held in [(true, false), (false, true), (true, true), (false, false)] {
            let reading = GrantReading { $0 == .screenRecording ? held.0 : held.1 }
            #expect(try GrantReading(line: reading.line) == reading)
        }
    }

    /// A line that does not name every grant exactly once, as true or false, is refused.
    @Test func aLineThatIsNotAReadingIsRefused() {
        for line in ["", "screenRecording=true", "screenRecording=true accessibility=yes",
                     "screenRecording=true accessibility=true accessibility=false",
                     "screenRecording=true accessibility=true microphone=true", "screenRecording true accessibility true"] {
            #expect(throws: GrantReadingFailure("unreadable grants line \"\(line)\"")) { try GrantReading(line: line) }
        }
    }

    /// The pane lists the outermost app: a helper inside one is charged to it.
    @Test func theHolderIsTheAppEnclosingTheResponsibleExecutable() {
        #expect(Holder(executable: "/Applications/iTerm.app/Contents/MacOS/iTerm2") == Holder(name: "iTerm", path: "/Applications/iTerm.app"))
        #expect(Holder(executable: "/Applications/Claude.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")
            == Holder(name: "Claude", path: "/Applications/Claude.app"))
        #expect(Holder(executable: "/usr/sbin/sshd") == Holder(name: "sshd", path: "/usr/sbin/sshd"))
    }

    /// A reading is the child's printed line; a child that fails or prints nonsense is said.
    @Test func aReadingIsTakenFromAChildProcess() async throws {
        let echo = URL(fileURLWithPath: "/bin/echo")
        #expect(try await GrantReading.taken(by: echo, ["screenRecording=false accessibility=true"])
            == GrantReading { $0 == .accessibility })
        await #expect(throws: GrantReadingFailure("unreadable grants line \"nonsense\"")) {
            try await GrantReading.taken(by: echo, ["nonsense"])
        }
        await #expect(throws: GrantReadingFailure("/usr/bin/false exited 1")) {
            try await GrantReading.taken(by: URL(fileURLWithPath: "/usr/bin/false"), [])
        }
        await #expect(throws: GrantReadingFailure("/bin/sleep 5 did not answer within 0.2 seconds")) {
            try await GrantReading.taken(by: URL(fileURLWithPath: "/bin/sleep"), ["5"], within: .milliseconds(200))
        }
        // A grandchild holding the pipe does not hold the call past its deadline.
        let start = ContinuousClock.now
        await #expect(throws: GrantReadingFailure.self) {
            try await GrantReading.taken(by: URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 5"], within: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    /// The child reads nothing of this process's stdin, and a child that says more than a
    /// pipe holds still answers.
    @Test func theChildNeitherSharesStdinNorStallsOnAFullPipe() async throws {
        let sh = URL(fileURLWithPath: "/bin/sh")
        await #expect(throws: GrantReadingFailure("unreadable grants line \"\"")) {
            try await GrantReading.taken(by: sh, ["-c", "cat"])
        }
        #expect(try await GrantReading.taken(by: sh, ["-c", "head -c 200000 /dev/zero >&2; echo screenRecording=true accessibility=true"])
            == GrantReading { _ in true })
    }
}

/// Which reader needs which grant is said once, and read back the same way.
struct GrantMappingTests {
    @Test func eachReaderNeedsTheGrantThatNamesIt() {
        #expect(Grant.accessibility.reader == .tree)
        #expect(Grant.screenRecording.reader == .pixels)
    }
}

/// Every gate of a process answers from one reading while it is fresh, and takes a new one after.
struct SharedReadingTests {
    actor Takes {
        var count = 0
        func take() -> GrantReading { count += 1; return GrantReading { $0 == .accessibility } }
    }

    @Test func gatesAskedTogetherShareOneReading() async throws {
        let takes = Takes()
        let shared = SharedReading(fresh: .seconds(60)) { await takes.take() }
        async let pixels = shared.holds(.screenRecording)
        async let tree = shared.holds(.accessibility)
        #expect(try await (pixels, tree) == (false, true))
        #expect(await takes.count == 1)
    }

    @Test func aStaleReadingIsTakenAgain() async throws {
        let takes = Takes()
        let shared = SharedReading(fresh: .zero) { await takes.take() }
        _ = try await shared.holds(.accessibility)
        _ = try await shared.holds(.accessibility)
        #expect(await takes.count == 2)
    }

    @Test func aReadingSlowerThanFreshIsStillTakenOnce() async throws {
        let takes = Takes()
        let shared = SharedReading(fresh: .zero) { try await Task.sleep(for: .milliseconds(200)); return await takes.take() }
        async let first = shared.holds(.accessibility)
        try await Task.sleep(for: .milliseconds(50))
        async let second = shared.holds(.accessibility)
        _ = try await (first, second)
        #expect(await takes.count == 1)
    }

    @Test func aCancelledGateStopsWaitingOnTheReading() async throws {
        let takes = Takes()
        let shared = SharedReading(fresh: .zero) { try await Task.sleep(for: .milliseconds(500)); return await takes.take() }
        let started = ContinuousClock.now
        let gate = Task { try await shared.holds(.accessibility) }
        try? await Task.sleep(for: .milliseconds(50))
        gate.cancel()
        await #expect(throws: CancellationError.self) { try await gate.value }
        #expect(ContinuousClock.now - started < .milliseconds(400))
        // The reading goes on, and is still the one a later gate waits on.
        #expect(try await shared.holds(.accessibility))
        #expect(await takes.count == 1)
    }
}

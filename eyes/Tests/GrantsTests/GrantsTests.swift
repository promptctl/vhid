import Foundation
import Grants
import Testing

struct GrantsTests {
    /// A reading survives the line a reading process prints for it.
    @Test func aReadingRoundTripsThroughItsLine() throws {
        for held in [(true, false), (false, true), (true, true), (false, false)] {
            let reading = GrantReading(held: [.screenRecording: held.0, .accessibility: held.1])
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
            == GrantReading(held: [.screenRecording: false, .accessibility: true]))
        await #expect(throws: GrantReadingFailure("unreadable grants line \"nonsense\"")) {
            try await GrantReading.taken(by: echo, ["nonsense"])
        }
        await #expect(throws: GrantReadingFailure("/usr/bin/false exited 1")) {
            try await GrantReading.taken(by: URL(fileURLWithPath: "/usr/bin/false"), [])
        }
        await #expect(throws: GrantReadingFailure("/bin/sleep 5 did not answer within 0.2 seconds")) {
            try await GrantReading.taken(by: URL(fileURLWithPath: "/bin/sleep"), ["5"], within: .milliseconds(200))
        }
    }
}

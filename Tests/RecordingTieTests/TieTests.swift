import Foundation
import Testing
@testable import RecordingTie

/// The tie between `vhid record` and its tap app, over a real socket and real processes.
@Suite struct TieTests {
    /// Messages cross both ways whole, a script's newlines included, and a closed end
    /// reads as the end.
    @Test func messagesCrossAndACloseEndsThem() throws {
        let listener = try TieListener()
        let app = try TieEnd.connect(to: listener.path)
        let command = try listener.accept(within: .seconds(1))
        try app.send(FromApp.recording)
        try app.send(FromApp.script("{\"to\":{\"x\":1,\"y\":2}}\n{\"t_ms\":0,\"keys\":[]}\n"))
        try command.send(ToApp.stop)
        #expect(try command.receive(FromApp.self) == .recording)
        #expect(try command.receive(FromApp.self) == .script("{\"to\":{\"x\":1,\"y\":2}}\n{\"t_ms\":0,\"keys\":[]}\n"))
        #expect(try app.receive(ToApp.self) == .stop)
        _ = consume app
        #expect(try command.receive(FromApp.self) == nil)
    }

    /// Only this user can reach the socket.
    @Test func theSocketsDirectoryIsTheUsersAlone() throws {
        let listener = try TieListener()
        let directory = (listener.path as NSString).deletingLastPathComponent
        let permissions = try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    /// An app that never connects is reported, not waited on forever.
    @Test func anAppThatNeverConnectsIsReported() throws {
        let listener = try TieListener()
        #expect(throws: TieFailure.self) { try listener.accept(within: .milliseconds(50)) }
    }

    /// An app with no command to connect to exits rather than tapping for nobody.
    @Test func connectingWithNoCommandFails() {
        #expect(throws: TieFailure.self) { try TieEnd.connect(to: "/tmp/vhid-record-no-such-socket") }
    }

    /// The command killed while the app records: the watch fires.
    @Test func theWatchFiresWhenTheCommandEnds() async throws {
        let command = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
        let ended = Ended()
        let watch = CommandWatch(pid: command.processIdentifier, queue: .global()) { ended.signal() }
        #expect(!ended.wait(.milliseconds(100)))
        kill(command.processIdentifier, SIGKILL)
        command.waitUntilExit()
        #expect(ended.wait(.seconds(5)))
        withExtendedLifetime(watch) {}
    }

    /// The command ended before the watch was set: it still fires, where a process source
    /// alone would wait forever. The child is left unreaped - a zombie, which `kill(pid, 0)`
    /// still finds - so its pid cannot be handed to another process mid-test, as a reaped
    /// one can while other tests spawn theirs.
    @Test func theWatchFiresForACommandAlreadyEnded() throws {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        #expect(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, nil) == 0)
        defer { var status: Int32 = 0; waitpid(pid, &status, 0) }
        var info = siginfo_t()
        #expect(waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == 0)
        #expect(kill(pid, 0) == 0)
        let ended = Ended()
        let watch = CommandWatch(pid: pid, queue: .global()) { ended.signal() }
        #expect(ended.wait(.seconds(5)))
        withExtendedLifetime(watch) {}
    }

    private final class Ended: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func signal() { semaphore.signal() }
        func wait(_ limit: Duration) -> Bool {
            semaphore.wait(timeout: .now() + .milliseconds(Int(limit.components.seconds * 1000 + limit.components.attoseconds / 1_000_000_000_000_000))) == .success
        }
    }
}

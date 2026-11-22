import Foundation
import OwnThread
import Testing
@testable import ChildProcess

/// What `Command` promises about the two streams it reads: both come back whole, and
/// neither the size of a stream nor the order the child writes them in changes what comes
/// back. The payload is deliberately past the ~64KB a kernel pipe buffer holds, because
/// that is the only size at which an unread child blocks in `write(2)` and the reading
/// order can matter at all. [LAW:behavior-not-structure] - nothing here knows how the
/// streams are drained, only that a stream never has to wait its turn.
@Suite(.ownThread) struct CommandTests {
    /// Past one pipe buffer on each stream, so a child nobody is reading blocks.
    static let size = 200_000

    /// `head -c` against /dev/zero is the cheapest large payload a shell can produce, and
    /// giving each stream a character of its own means a swap cannot pass as a success.
    static func fill(_ stream: String) -> String {
        let redirect = stream == "e" ? " >&2" : ""
        return "head -c \(size) /dev/zero | tr '\\0' '\(stream)'\(redirect)"
    }

    /// Both orders, because the promise is that the order does not matter. Written the
    /// other way - stderr first - the child fills stderr and stops, and a reader that
    /// takes stdout to completion first waits for an end the child can no longer reach.
    @Test(.timeLimit(.minutes(1)), arguments: [["e", "o"], ["o", "e"]])
    func bothStreamsComeBackWholeWhicheverIsWrittenFirst(order: [String]) throws {
        let output = try Command("/bin/sh", "-c", order.map(Self.fill).joined(separator: "; ")).run(by: .within(hangGuard, or: .never))
        #expect(output.status == 0)
        #expect(output.stdout == String(repeating: "o", count: Self.size))
        #expect(output.stderr == String(repeating: "e", count: Self.size))
    }

    @Test func theStatusAndBothStreamsSurviveAFailingCommand() throws {
        let output = try Command("/bin/sh", "-c", "echo out; echo err >&2; exit 3").run(by: .within(hangGuard, or: .never))
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
        #expect(output.merged == "out\nerr")
    }

    /// A command a signal ended has that signal for its status, as one that exited has what
    /// it exited with.
    @Test func theStatusOfACommandEndedByASignalIsTheSignal() throws {
        #expect(try Command("/bin/sh", "-c", "kill -KILL $$").run(by: .within(hangGuard, or: .never)).status == SIGKILL)
    }

    /// A command that has returned holds nothing open, on a thread that never drains a
    /// pool as much as on one that does: vhidd runs the driver probe every two seconds
    /// from a thread that never returns, and four commands a probe each leaving two
    /// descriptors behind would be the whole table within the minute. Counted in a process
    /// of its own, where nothing else opens a descriptor, so the count is exact.
    @Test func aCommandThatHasReturnedHoldsNoDescriptorOpen() async {
        await #expect(processExitsWith: .success) {
            let run = { try Command("/usr/bin/true").run(by: .within(hangGuard, or: .never)).status }
            #expect(try run() == 0)
            let before = try openDescriptors()
            let ran = try (0..<100).count { _ in try run() == 0 }
            #expect(ran == 100)
            #expect(try openDescriptors() == before)
        }
    }

    /// A command that never ends is given up on at its limit and said by name, with the
    /// limit, and the child is stopped and collected before the reading that gave up on it
    /// hears so: in a process of its own, no child of any kind is left.
    @Test func aCommandThatNeverEndsIsStoppedAtItsLimitAndNamed() async {
        await #expect(processExitsWith: .success) {
            let overran = #expect(throws: Command.Overran.self) {
                try Command("/bin/sh", "-c", "exec sleep 3600").run(by: .within(.milliseconds(500), or: .never))
            }
            let named = try #require(overran)
            #expect(named.command == "sh -c exec sleep 3600")
            #expect(named.limit == .milliseconds(500))
            let ran = try #require(named.ran)
            #expect(ran >= .milliseconds(500))
            #expect(named.description == "`sh -c exec sleep 3600` had not ended \(ran) after it was started, at the limit of 0.5 seconds, and was given up on")
            #expect(noChildLeft())
        }
    }

    /// A child that has exited can leave its streams open in something it started, and
    /// the end of a stream is what a reading waits for: the limit covers that wait too.
    /// What holds the stream sleeps for the hang guard, so only a hang outlasts it.
    @Test func aStreamHeldOpenPastTheChildsExitIsGivenUpOnAtTheLimit() throws {
        #expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", heldPastExit).run(by: .within(.milliseconds(500), or: .never))
        }
    }

    /// The limit is the reading's: a command run by a deadline another has used up is
    /// refused, where a limit apiece would let two commands take the reading twice as long
    /// as its caller gave it. Refused before it starts, because a command can act as it
    /// starts. [LAW:single-enforcer]
    @Test func commandsRunByOneDeadlineShareItsLimit() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let deadline = Command.Deadline.within(.milliseconds(500), or: .never)
        let first = try #require(#expect(throws: Command.Overran.self) { try Command("/bin/sleep", "3600").run(by: deadline) })
        #expect(try #require(first.ran) >= .milliseconds(500))
        let second = try #require(#expect(throws: Command.Overran.self) { try Command("/usr/bin/touch", marker.path).run(by: deadline) })
        #expect(second == Command.Overran(command: "touch \(marker.path)", ran: nil, limit: .milliseconds(500)))
        #expect(second.description == "`touch \(marker.path)` was not started: the limit of 0.5 seconds had run out before it")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A deadline already past when its command comes to start starts nothing.
    @Test func aCommandRunByASpentDeadlineIsNeverStarted() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let overran = #expect(throws: Command.Overran.self) {
            try Command("/usr/bin/touch", marker.path).run(by: .within(.zero, or: .never))
        }
        #expect(overran?.ran == .some(nil))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A command given up on holds nothing open either: vhidd reads the driver every two
    /// seconds while it waits, and a stuck tool is stuck at every one of them. Both ways of
    /// overrunning: a child that never ends, whose streams end when it is stopped, and one
    /// that has ended and left its streams open in something it started, where giving up is
    /// all that lets go of them.
    @Test(arguments: ["exec sleep 3600", heldPastExit])
    func aCommandGivenUpOnHoldsNoDescriptorOpen(script: String) async {
        await #expect(processExitsWith: .success) { [script] () async throws in
            let run = { () -> Bool in
                do { _ = try Command("/bin/sh", "-c", script).run(by: .within(.milliseconds(100), or: .never)); return false } catch { return error is Command.Overran }
            }
            #expect(run())
            let before = try openDescriptors()
            #expect((0..<10).allSatisfy { _ in run() })
            #expect(try openDescriptors() == before)
        }
    }

    /// A reading stopped while a command runs ends at once, the command with it: thrown as
    /// a cancel, not as a command that failed or overran, and the child stopped and
    /// collected by the time it is thrown, as one given up on at its limit is. The stop is
    /// pulled once the child has said, through a FIFO, that it runs.
    @Test func aCommandWhoseReadingIsStoppedEndsAtOnceAndLeavesNoChild() throws {
        let running = try FIFO()
        let stop = Command.Stop()
        let ended = Gate<Result<Command.Output, any Error>?>(nil)
        Thread.detachNewThread {
            let result = Result { try Command("/bin/sh", "-c", "echo $$ > \(running.path); exec sleep 3600").run(by: .within(hangGuard, or: stop)) }
            ended.update { $0 = result }
        }
        let child = try #require(pid_t(running.readLine()))
        stop.pull()
        let result = try ended.wait(for: "the stopped command to end") { $0 }
        #expect(throws: CancellationError.self) { try result.get() }
        // Signal 0 reaches a zombie as much as a running child, so this is the child both
        // stopped and collected.
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    /// A stop stays pulled: no command a stopped reading runs after it is started, so a
    /// reading of several commands runs none past the one it stopped.
    @Test func aCommandRunByAStoppedReadingIsNeverStarted() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let stop = Command.Stop()
        stop.pull()
        let deadline = Command.Deadline.within(hangGuard, or: stop)
        for _ in 0..<2 {
            #expect(throws: CancellationError.self) { try Command("/usr/bin/touch", marker.path).run(by: deadline) }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(stop.ended.isEmpty)
    }
}

/// A shell that exits at once and leaves its streams held by a child for the hang guard,
/// which outlives any limit a test gives and ends on its own after.
private let heldPastExit = "sleep \(hangGuard.components.seconds) & exit 0"

/// The descriptors this process has open, listed rather than probed slot by slot: the
/// table's size is a limit, and where the limit is lifted there are more slots than a
/// test has time to ask about.
private func openDescriptors() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }

/// Whether this process has no child, running or uncollected. Exact only in a process
/// that starts nothing else, which an exit test's is.
private func noChildLeft() -> Bool {
    var status: Int32 = 0
    return waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD
}

/// A named pipe a child writes to say it runs: reading it waits for the child's word, so
/// the test acts once the child is there and never on a guess about how long that takes.
final class FIFO: Sendable {
    let path: String

    init() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "vhid-fifo-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { unlink(path) }

    /// The first line written, once a writer has written it.
    func readLine() -> String {
        let handle = FileHandle(forReadingAtPath: path)
        let data = handle?.readDataToEndOfFile() ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

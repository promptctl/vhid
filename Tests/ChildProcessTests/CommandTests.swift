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
        let output = try Command("/bin/sh", "-c", order.map(Self.fill).joined(separator: "; ")).run(by: .within(.seconds(30), or: .never))
        #expect(output.status == 0)
        #expect(output.stdout == String(repeating: "o", count: Self.size))
        #expect(output.stderr == String(repeating: "e", count: Self.size))
    }

    @Test func theStatusAndBothStreamsSurviveAFailingCommand() throws {
        let output = try Command("/bin/sh", "-c", "echo out; echo err >&2; exit 3").run(by: .within(.seconds(30), or: .never))
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
        #expect(output.merged == "out\nerr")
    }

    /// A command a signal ended has that signal for its status, as one that exited has what
    /// it exited with.
    @Test func theStatusOfACommandEndedByASignalIsTheSignal() throws {
        #expect(try Command("/bin/sh", "-c", "kill -KILL $$").run(by: .within(.seconds(30), or: .never)).status == SIGKILL)
    }

    /// A FIFO of the test's own, which a child opens to say it got as far as the open, or
    /// blocks in until this side opens the other end. The order it forces is the test's,
    /// on any runner. [LAW:no-ambient-temporal-coupling]
    static func fifo() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appending(path: "vhid-command-\(UUID().uuidString)")
        try #require(mkfifo(path.path, 0o600) == 0)
        return path
    }

    /// A command that never ends is given up on at its limit and said by name, with the
    /// limit. It cannot end on its own, so its returning at all is the limit's doing.
    @Test(.timeLimit(.minutes(1))) func aCommandThatNeverEndsIsStoppedAtItsLimitAndNamed() throws {
        let overran = #expect(throws: Command.Overran.self) {
            try Command("/bin/sleep", "600").run(by: .within(.milliseconds(500), or: .never))
        }
        let named = try #require(overran)
        #expect(named.command == "sleep 600")
        #expect(named.limit == .milliseconds(500))
        #expect(named.description == "`sleep 600` had not ended \(named.ran) after it was started, at the limit of 0.5 seconds, and was given up on")
    }

    /// A child that has exited can leave its streams open in something it started, and
    /// the end of a stream is what a reading waits for: the limit covers that wait too. What
    /// it started holds the streams until this side opens the FIFO it blocks on, which is
    /// only once the command has been given up on.
    @Test(.timeLimit(.minutes(1))) func aStreamHeldOpenPastTheChildsExitIsGivenUpOnAtTheLimit() throws {
        let held = try Self.fifo()
        defer { try? FileManager.default.removeItem(at: held) }
        #expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", "cat \"$0\" & exit 0", held.path).run(by: .within(.milliseconds(500), or: .never))
        }
        // Lets what it started go: its open ends with this one, and it reads the end.
        close(open(held.path, O_WRONLY))
    }

    /// The limit is the reading's: a command run by a deadline that others have spent is
    /// given only what is left, where a limit of its own would let two commands take the
    /// reading twice as long as its caller gave it. Spent here before the command starts,
    /// so the command is given up on at its first look on any runner, and the error names
    /// the reading's limit.
    @Test(.timeLimit(.minutes(1))) func aCommandIsGivenOnlyWhatItsDeadlineHasLeft() async throws {
        let deadline = Command.Deadline.within(.milliseconds(50), or: .never)
        // On the deadline's own clock, which a sleeping Mac stops.
        try await SuspendingClock().sleep(for: .milliseconds(50))
        let overran = try #require(#expect(throws: Command.Overran.self) { try Command("/usr/bin/true").run(by: deadline) })
        #expect(overran.limit == .milliseconds(50))
    }

    /// A reading stopped while a command runs ends at once, the command with it: thrown as
    /// a cancel, not as a command that failed or overran, and the child stopped and
    /// collected by the time it is thrown, as one given up on at its limit is. The child
    /// never ends on its own and the limit is far past it, so the stop is what ended it.
    @Test(.timeLimit(.minutes(1))) func aCommandWhoseReadingIsStoppedEndsAtOnceAndLeavesNoChild() async throws {
        let running = try Self.fifo()
        defer { try? FileManager.default.removeItem(at: running) }
        let stop = Command.Stop()
        // On a thread of its own, as a reading is taken: the command blocks the thread it
        // runs on, and the cooperative pool may have only the one.
        let (ending, end) = AsyncStream<Result<Command.Output, any Error>>.makeStream()
        Thread.detachNewThread {
            end.yield(Result { try Command("/bin/sh", "-c", "echo $$ > \"$0\"; exec sleep 600", running.path).run(by: .within(.seconds(30), or: stop)) })
            end.finish()
        }
        // Blocks until the child has written its pid: the stop lands while it runs.
        let said = try #require(FileHandle(forReadingAtPath: running.path)?.readDataToEndOfFile())
        let child = try #require(pid_t(String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        stop.pull()
        var ended: Result<Command.Output, any Error>?
        for await result in ending { ended = result }
        let endedResult = try #require(ended)
        #expect(throws: CancellationError.self) { try endedResult.get() }
        // Signal 0 reaches a zombie as much as a running child, so this is the child both
        // stopped and collected, and by the time the command was thrown: nothing is left
        // to collect it afterwards.
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    /// A stop stays pulled: no command a stopped reading runs after it is started, so a
    /// reading of several commands runs none past the one it stopped.
    @Test(.timeLimit(.minutes(1))) func aCommandRunByAStoppedReadingIsNeverStarted() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let stop = Command.Stop()
        stop.pull()
        let deadline = Command.Deadline.within(.seconds(30), or: stop)
        for _ in 0..<2 {
            #expect(throws: CancellationError.self) { try Command("/usr/bin/touch", marker.path).run(by: deadline) }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(stop.ended.isEmpty)
    }
}

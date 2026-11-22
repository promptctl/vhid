import Foundation
import OwnThread
import TestClock
import Testing
import Time
@testable import ChildProcess

/// What `Command` promises about the two streams it reads: both come back whole, and
/// neither the size of a stream nor the order the child writes them in changes what comes
/// back. The payload is deliberately past the ~64KB a kernel pipe buffer holds, because
/// that is the only size at which an unread child blocks in `write(2)` and the reading
/// order can matter at all. [LAW:behavior-not-structure] - nothing here knows how the
/// streams are drained, only that no stream is left to be read after another.
///
/// Every limit is on a test clock, which moves only when a test moves it: a command the
/// test does not give up on is never given up on however slowly the Mac runs it, and one it
/// does is given up on exactly at its limit. A child says it is running through a `Fifo`.
@Suite(.ownThread) struct CommandTests {
    /// Past one pipe buffer on each stream, so a child nobody is reading blocks.
    static let size = 200_000

    /// `head -c` against /dev/zero is the cheapest large payload a shell can produce, and
    /// giving each stream a character of its own means a swap cannot pass as a success.
    static func fill(_ stream: String) -> String {
        let redirect = stream == "e" ? " >&2" : ""
        return "head -c \(size) /dev/zero | tr '\\0' '\(stream)'\(redirect)"
    }

    /// A deadline that never passes, on a clock nothing moves.
    static var unhurried: Deadline { .within(.seconds(30), on: ManualClock().timeline) }

    /// Both orders, because the promise is that the order does not matter. Written the
    /// other way - stderr first - the child fills stderr and stops, and a reader that
    /// takes stdout to completion first waits for an end the child can no longer reach.
    @Test(arguments: [["e", "o"], ["o", "e"]])
    func bothStreamsComeBackWholeWhicheverIsWrittenFirst(order: [String]) throws {
        let output = try Command("/bin/sh", "-c", order.map(Self.fill).joined(separator: "; ")).run(by: Self.unhurried, or: .never)
        #expect(output.status == 0)
        #expect(output.stdout == String(repeating: "o", count: Self.size))
        #expect(output.stderr == String(repeating: "e", count: Self.size))
    }

    @Test func theStatusAndBothStreamsSurviveAFailingCommand() throws {
        let output = try Command("/bin/sh", "-c", "echo out; echo err >&2; exit 3").run(by: Self.unhurried, or: .never)
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
        #expect(output.merged == "out\nerr")
    }

    /// A command a signal ended has that signal for its status, as one that exited has what
    /// it exited with.
    @Test func theStatusOfACommandEndedByASignalIsTheSignal() throws {
        #expect(try Command("/bin/sh", "-c", "kill -KILL $$").run(by: Self.unhurried, or: .never).status == SIGKILL)
    }

    /// A command that has returned holds nothing open, on a thread that never drains a
    /// pool as much as on one that does: vhidd runs the driver probe every two seconds
    /// from a thread that never returns, and four commands a probe each leaving two
    /// descriptors behind would be the whole table within the minute.
    ///
    /// The count is the process's, and other tests open descriptors of their own while
    /// this runs, so what is checked is that it did not grow by the 200 that 100 leaking
    /// runs leave.
    @Test func aCommandThatHasReturnedHoldsNoDescriptorOpen() throws {
        let done = Latch()
        nonisolated(unsafe) var counted: Result<(ran: Int, grew: Int), any Error>?
        Thread.detachNewThread {
            counted = Result {
                let before = try Self.open()
                let ran = (0..<100).count { _ in (try? Command("/usr/bin/true").run(by: Self.unhurried, or: .never))?.status == 0 }
                return (ran, try Self.open() - before)
            }
            done.open()
        }
        try #require(done.wait("the hundred runs"))
        let (ran, grew) = try #require(counted).get()
        #expect(ran == 100)
        #expect(grew < 100)
    }

    /// Listed, not probed slot by slot: the table's size is a limit, and where the limit is
    /// lifted there are more slots than a test has time to ask about.
    @Sendable static func open() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }

    /// Runs `command` by `deadline` on a thread of its own, as a reading is taken.
    static func running(_ command: Command, by deadline: Deadline, or stop: Command.Stop = .never) -> Pending<Command.Output> {
        Pending { try command.run(by: deadline, or: stop) }
    }

    /// A command that never ends is given up on at its limit and said by name, with the
    /// limit, and the child is stopped and not left running behind the reading that gave up
    /// on it.
    @Test func aCommandThatNeverEndsIsStoppedAtItsLimitAndNamed() throws {
        let clock = ManualClock(), running = try Fifo()
        let command = Command("/bin/sh", "-c", "echo $$ > \(running.path); exec sleep 600")
        let ended = Self.running(command, by: .within(.milliseconds(500), on: clock.timeline))
        let pid = try #require(running.said().flatMap { pid_t($0) })
        clock.advance(by: .milliseconds(500))
        let overran = try #require(#expect(throws: Command.Overran.self) { try ended.get() })
        #expect(overran.command == "sh -c echo $$ > \(running.path); exec sleep 600")
        #expect(overran.limit == .milliseconds(500))
        #expect(overran.ran == .milliseconds(500))
        #expect(overran.description == "`\(overran.command)` had not ended 0.5 seconds after it was started, at the limit of 0.5 seconds, and was given up on")
        // Signal 0 reaches a zombie as much as a running child, so this is the child both
        // stopped and collected, and by the time the command was thrown: nothing is left
        // to collect it afterwards.
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    /// A child that has exited can leave its streams open in something it started, and
    /// the end of a stream is what a reading waits for: the limit covers that wait too. A
    /// reading that waited for the stream instead would answer, never given up on.
    @Test func aStreamHeldOpenPastTheChildsExitIsGivenUpOnAtTheLimit() throws {
        let clock = ManualClock(), started = try Fifo()
        let ended = Self.running(Command("/bin/sh", "-c", "sleep 600 & echo > \(started.path); exit 0"), by: .within(.milliseconds(500), on: clock.timeline))
        try #require(started.said() != nil)
        clock.advance(by: .milliseconds(500))
        #expect(throws: Command.Overran.self) { try ended.get() }
    }

    /// The limit is the reading's: a command run by a deadline another has used most of is
    /// given what is left, where a limit of its own would let two commands take the reading
    /// twice as long as its caller gave it. The error says both: how long this command had,
    /// and the limit.
    @Test func commandsRunByOneDeadlineShareItsLimit() throws {
        let clock = ManualClock(), running = try Fifo()
        let deadline = Deadline.within(.seconds(3), on: clock.timeline)
        #expect(try Command("/usr/bin/true").run(by: deadline, or: .never).status == 0)
        clock.advance(by: .seconds(1))
        let ended = Self.running(Command("/bin/sh", "-c", "echo > \(running.path); exec sleep 600"), by: deadline)
        try #require(running.said() != nil)
        clock.advance(by: .seconds(2))
        let overran = try #require(#expect(throws: Command.Overran.self) { try ended.get() })
        #expect(overran.ran == .seconds(2))
        #expect(overran.limit == .seconds(3))
    }

    /// A command whose reading's limit has passed before it could start is not started, and says
    /// so with the limit and how long the reading had run.
    @Test func aCommandWhoseLimitHasPassedIsNeverStarted() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let clock = ManualClock()
        let deadline = Deadline.within(.seconds(1), on: clock.timeline)
        clock.advance(by: .milliseconds(1500))
        let unstarted = try #require(#expect(throws: Command.Unstarted.self) { try Command("/usr/bin/touch", marker.path).run(by: deadline, or: .never) })
        #expect(unstarted == Command.Unstarted(command: "touch \(marker.path)", limit: .seconds(1), spent: .milliseconds(1500)))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A command given up on holds nothing open either: vhidd reads the driver every two
    /// seconds while it waits, and a stuck tool is stuck at every one of them. Both ways of
    /// overrunning: a child that never ends, whose streams end when it is stopped, and one
    /// that has ended and left its streams open in something it started, where giving up is
    /// all that lets go of them.
    ///
    /// What it started outlives the giving up and holds both streams: once the run has
    /// returned it writes to each, SIGPIPE ignored, and says whether each write found the
    /// end this side read from closed - a status of 1 for each.
    @Test(arguments: ["exec sleep 600", "exit 0"])
    func aCommandGivenUpOnHoldsNoDescriptorOpen(ending: String) throws {
        let clock = ManualClock(), started = try Fifo(), go = try Fifo(), wrote = try Fifo()
        let outliving = "(trap '' PIPE; read _ < \(go.path); /bin/echo x 2>/dev/null; out=$?; /bin/echo x >&2 2>/dev/null; echo \"$out $?\" > \(wrote.path)) &"
        let command = Command("/bin/sh", "-c", "\(outliving) echo > \(started.path); \(ending)")
        let running = Self.running(command, by: .within(.seconds(1), on: clock.timeline))
        try #require(started.said() != nil)
        clock.advance(by: .seconds(1))
        #expect(throws: Command.Overran.self) { try running.get() }
        go.say()
        #expect(wrote.said() == "1 1")
    }

    /// A reading stopped while a command runs ends at once, the command with it: thrown as
    /// a cancel, not as a command that failed or overran, and the child stopped and
    /// collected by the time it is thrown, as one given up on at its limit is.
    @Test func aCommandWhoseReadingIsStoppedEndsAtOnceAndLeavesNoChild() throws {
        let stop = Command.Stop(), running = try Fifo()
        let ended = Self.running(Command("/bin/sh", "-c", "echo $$ > \(running.path); exec sleep 600"), by: Self.unhurried, or: stop)
        let pid = try #require(running.said().flatMap { pid_t($0) })
        stop.pull()
        #expect(throws: CancellationError.self) { try ended.get() }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    /// A stop stays pulled: no command a stopped reading runs after it is started, so a
    /// reading of several commands runs none past the one it stopped.
    @Test func aCommandRunByAStoppedReadingIsNeverStarted() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let stop = Command.Stop()
        stop.pull()
        for _ in 0..<2 {
            #expect(throws: CancellationError.self) { try Command("/usr/bin/touch", marker.path).run(by: Self.unhurried, or: stop) }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(stop.ended.isEmpty)
    }

    /// A reading's limit counts the wait for a thread to read on: one whose queue was held
    /// past its limit starts no command once the queue runs it.
    @Test func aReadingDequeuedPastItsLimitStartsNothing() async throws {
        let clock = ManualClock(), queue = DispatchQueue(label: "CommandTests.held"), held = Gate()
        queue.async { held.arrive() }
        held.arrived.wait()
        let deadline = Deadline.within(.seconds(1), on: clock.timeline)
        let read = Task {
            try await reading(by: deadline, on: queue) { deadline, stop in Result { try Command("/usr/bin/true").run(by: deadline, or: stop) } }
        }
        clock.advance(by: .seconds(1))
        held.open()
        await #expect(throws: Command.Unstarted.self) { try await read.value.get() }
    }
}

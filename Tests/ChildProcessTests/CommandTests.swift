import Foundation
import OwnThread
import TestClock
import Testing
import Timeline
import Waiting
@testable import ChildProcess

/// A deadline for a command that is going to end: the guard, so only a hang fails it.
func guarded() -> Deadline { Timeline.suspending.deadline(within: hangGuard) }

/// What `Command` promises about the two streams it reads: both come back whole, and
/// neither the size of a stream nor the order the child writes them in changes what comes
/// back. The payload is deliberately past the ~64KB a kernel pipe buffer holds, because
/// that is the only size at which an unread child blocks in `write(2)` and the reading
/// order can matter at all. [LAW:behavior-not-structure] - nothing here knows how the
/// streams are drained, only that a stream never has to wait its turn.
@Suite(.ownThread, .hangGuarded) struct CommandTests {
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
    @Test(arguments: [["e", "o"], ["o", "e"]])
    func bothStreamsComeBackWholeWhicheverIsWrittenFirst(order: [String]) throws {
        let output = try Command("/bin/sh", "-c", order.map(Self.fill).joined(separator: "; ")).run(by: guarded(), or: .never)
        #expect(output.status == 0)
        #expect(output.stdout == String(repeating: "o", count: Self.size))
        #expect(output.stderr == String(repeating: "e", count: Self.size))
    }

    @Test func theStatusAndBothStreamsSurviveAFailingCommand() throws {
        let output = try Command("/bin/sh", "-c", "echo out; echo err >&2; exit 3").run(by: guarded(), or: .never)
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
        #expect(output.merged == "out\nerr")
    }

    /// A command a signal ended has that signal for its status, as one that exited has what
    /// it exited with.
    @Test func theStatusOfACommandEndedByASignalIsTheSignal() throws {
        #expect(try Command("/bin/sh", "-c", "kill -KILL $$").run(by: guarded(), or: .never).status == SIGKILL)
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
        // Listed, not probed slot by slot: the table's size is a limit, and where the
        // limit is lifted there are more slots than a test has time to ask about.
        @Sendable func open() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var counted: Result<(ran: Int, grew: Int), any Error>?
        Thread.detachNewThread {
            counted = Result {
                let before = try open()
                let ran = (0..<100).count { _ in (try? Command("/usr/bin/true").run(by: guarded(), or: .never))?.status == 0 }
                return (ran, try open() - before)
            }
            done.signal()
        }
        done.wait()
        let (ran, grew) = try #require(counted).get()
        #expect(ran == 100)
        #expect(grew < 100)
    }

    /// A command that never ends is given up on at its limit and said by name, with the
    /// limit, and the child is stopped and not left running behind the reading that gave up
    /// on it.
    ///
    /// The child says its pid before it sleeps, and the limit is spent only once it has: the
    /// command's deadline is on a clock this test moves, past the limit at the child's word,
    /// so the child is always there to be found stopped, however slowly it started.
    @Test func aCommandThatNeverEndsIsStoppedAtItsLimitAndNamed() throws {
        let said = try Handshake()
        let clock = ManualClock()
        let deadline = Timeline(clock).deadline(within: .milliseconds(500))
        let script = "echo $$ > \"$0\"; exec sleep 600"
        let child = Latch<pid_t?>(nil)
        Thread.detachNewThread {
            guard let pid = (try? said.line()).flatMap({ pid_t($0) }) else { return }
            child.update { $0 = pid }
            clock.advance(by: .milliseconds(500))
        }
        let overran = #expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", script, said.path).run(by: deadline, or: .never)
        }
        let named = try #require(overran)
        #expect(named.command == "sh -c \(script) \(said.path)")
        #expect(named.limit == .milliseconds(500))
        #expect(named.ran == .milliseconds(500))
        #expect(named.description == "`\(named.command)` had not ended \(named.ran) after it was started, at the limit of 0.5 seconds, and was given up on")
        let pid = try #require(child.current)
        // Signal 0 reaches a zombie as much as a running child, so this is the child both
        // stopped and collected, and by the time the command was thrown: nothing is left
        // to collect it afterwards.
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    /// A child that has exited can leave its streams open in something it started, and
    /// the end of a stream is what a reading waits for: the limit covers that wait too.
    @Test func aStreamHeldOpenPastTheChildsExitIsGivenUpOnAtTheLimit() throws {
        #expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", "sleep 600 & exit 0").run(by: Timeline.suspending.deadline(within: .milliseconds(500)), or: .never)
        }
    }

    /// The limit is the reading's: a command run by a deadline that another has used most
    /// of is given what is left, where a limit of its own would let two commands take the
    /// reading twice as long as its caller gave it. The clock is held, so "most of it" is
    /// exactly what this test spent: the second command is given the quarter second left
    /// of thirty, and that quarter, spent once the command has said it runs, ends it - a
    /// limit of its own would still have twenty-nine seconds and more to run. The error
    /// names both: the quarter it had, and the reading's limit.
    @Test func commandsRunByOneDeadlineShareItsLimit() throws {
        let said = try Handshake()
        let clock = ManualClock()
        let deadline = Timeline(clock).deadline(within: .seconds(30))
        #expect(try Command("/usr/bin/true").run(by: deadline, or: .never).status == 0)
        clock.advance(by: .milliseconds(29_750))
        Thread.detachNewThread { if (try? said.line()) != nil { clock.advance(by: .milliseconds(250)) } }
        let overran = try #require(#expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", "echo $$ > \"$0\"; exec sleep 600", said.path).run(by: deadline, or: .never)
        })
        #expect(overran.ran == .milliseconds(250))
        #expect(overran.limit == .seconds(30))
    }

    /// A command whose turn comes after its reading's deadline is not started: nothing is
    /// spawned, and the error says the limit that had passed.
    @Test func aCommandWhoseDeadlineHasPassedIsNeverStarted() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let clock = ManualClock()
        let deadline = Timeline(clock).deadline(within: .seconds(30))
        clock.advance(by: .seconds(30))
        let unstarted = #expect(throws: Command.Unstarted.self) { try Command("/usr/bin/touch", marker.path).run(by: deadline, or: .never) }
        #expect(unstarted == Command.Unstarted(command: "touch \(marker.path)", limit: .seconds(30)))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A reading's limit counts from when it was asked for, not from when a thread came to
    /// run it: the queue it runs on is held here while its whole limit passes, and the
    /// command it then runs is never started.
    @Test func aReadingsLimitCountsFromWhenItWasAskedFor() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let clock = ManualClock()
        let held = Latch<(@Sendable () -> Void)?>(nil)
        async let ran = reading(within: .seconds(30), on: Timeline(clock), enqueue: { work in held.update { $0 = work } }) { deadline, stop in
            Result { try Command("/usr/bin/touch", marker.path).run(by: deadline, or: stop) }
        }
        let work = try held.wait(for: "the reading's work") { $0 }
        clock.advance(by: .seconds(30))
        Thread.detachNewThread(work)
        let result = try await ran
        #expect(throws: Command.Unstarted.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A command given up on holds nothing open either: vhidd reads the driver every two
    /// seconds while it waits, and a stuck tool is stuck at every one of them. Both ways of
    /// overrunning: a child that never ends, whose streams end when it is stopped, and one
    /// that has ended and left its streams open in something it started, where giving up is
    /// all that lets go of them. That one is given long enough for the shell to have exited.
    @Test(arguments: [
        ("exec sleep 600", Duration.milliseconds(20), 50),
        ("sleep 20 & exit 0", Duration.milliseconds(300), 10),
    ])
    func aCommandGivenUpOnHoldsNoDescriptorOpen(script: String, limit: Duration, runs: Int) throws {
        @Sendable func open() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var counted: Result<(overran: Int, grew: Int), any Error>?
        Thread.detachNewThread {
            counted = Result {
                let before = try open()
                let overran = (0..<runs).count { _ in
                    do { _ = try Command("/bin/sh", "-c", script).run(by: Timeline.suspending.deadline(within: limit), or: .never); return false } catch { return error is Command.Overran }
                }
                return (overran, try open() - before)
            }
            done.signal()
        }
        done.wait()
        let (overran, grew) = try #require(counted).get()
        #expect(overran == runs)
        #expect(grew < runs)
    }

    /// A reading stopped while a command runs ends at once, the command with it: thrown as
    /// a cancel, not as a command that failed or overran, and the child stopped and
    /// collected by the time it is thrown, as one given up on at its limit is.
    @Test func aCommandWhoseReadingIsStoppedEndsAtOnceAndLeavesNoChild() throws {
        let said = try Handshake()
        let stop = Command.Stop()
        let ended = Latch<Result<Command.Output, any Error>?>(nil)
        // On a thread of its own, as a reading is taken: the command blocks the thread it
        // runs on.
        Thread.detachNewThread {
            let result = Result { try Command("/bin/sh", "-c", "echo $$ > \"$0\"; exec sleep 600", said.path).run(by: guarded(), or: stop) }
            ended.update { $0 = result }
        }
        let child = try #require(pid_t(try said.line()))
        stop.pull()
        let result = try ended.wait(for: "the stopped command to end") { $0 }
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    /// A stop stays pulled: no command a stopped reading runs after it is started, so a
    /// reading of several commands runs none past the one it stopped.
    @Test func aCommandRunByAStoppedReadingIsNeverStarted() throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let stop = Command.Stop()
        stop.pull()
        let deadline = guarded()
        for _ in 0..<2 {
            #expect(throws: CancellationError.self) { try Command("/usr/bin/touch", marker.path).run(by: deadline, or: stop) }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(stop.ended.isEmpty)
    }
}

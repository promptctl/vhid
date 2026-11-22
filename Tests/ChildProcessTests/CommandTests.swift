import Foundation
import OwnThread
import Testing
import Waiting
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
        let output = try Command("/bin/sh", "-c", order.map(Self.fill).joined(separator: "; ")).run(by: .within(hangGuard))
        #expect(output.status == 0)
        #expect(output.stdout == String(repeating: "o", count: Self.size))
        #expect(output.stderr == String(repeating: "e", count: Self.size))
    }

    @Test func theStatusAndBothStreamsSurviveAFailingCommand() throws {
        let output = try Command("/bin/sh", "-c", "echo out; echo err >&2; exit 3").run(by: .within(hangGuard))
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
        #expect(output.merged == "out\nerr")
    }

    /// A command a signal ended has that signal for its status, as one that exited has what
    /// it exited with.
    @Test func theStatusOfACommandEndedByASignalIsTheSignal() throws {
        #expect(try Command("/bin/sh", "-c", "kill -KILL $$").run(by: .within(hangGuard)).status == SIGKILL)
    }

    /// A command that has returned holds nothing open, on a thread that never drains a
    /// pool as much as on one that does: vhidd runs the driver probe every two seconds
    /// from a thread that never returns, and four commands a probe each leaving two
    /// descriptors behind would be the whole table within the minute.
    ///
    /// The count is the process's, so it is taken in a process of its own, where no other
    /// test opens anything: what is checked is that it did not grow by the 200 that 100
    /// leaking runs leave.
    @Test(.timeLimit(.minutes(2))) func aCommandThatHasReturnedHoldsNoDescriptorOpen() async {
        await #expect(processExitsWith: .success) {
            let (ran, grew) = try onAThreadOfItsOwn {
                let before = try Self.descriptors()
                let ran = (0..<100).count { _ in (try? Command("/usr/bin/true").run(by: .within(hangGuard)))?.status == 0 }
                return (ran, try Self.descriptors() - before)
            }
            guard ran == 100, grew < 100 else {
                FileHandle.standardError.write(Data("\(ran) of 100 ran, and the descriptors grew by \(grew)\n".utf8))
                exit(1)
            }
        }
    }

    /// A command that never ends is given up on at its limit and said by name, with the
    /// limit and how long it had.
    @Test(.timeLimit(.minutes(2))) func aCommandThatNeverEndsIsGivenUpOnAtItsLimitAndNamed() throws {
        let overran = try #require(#expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", "exec sleep 3600").run(by: .within(.milliseconds(200)))
        })
        #expect(overran.command == "sh -c exec sleep 3600")
        #expect(overran.limit == .milliseconds(200))
        #expect(overran.ran >= .milliseconds(200))
        #expect(overran.description == "`sh -c exec sleep 3600` had not ended \(overran.ran) after it was started, at the limit of 0.2 seconds, and was given up on")
    }

    /// A command given up on is stopped and collected by the time it is thrown: nothing of
    /// it is left running or left to collect. In a process of its own, where it is the only
    /// child there could be.
    @Test func aCommandGivenUpOnLeavesNoChild() async {
        await #expect(processExitsWith: .success) {
            _ = try? Command("/bin/sh", "-c", "exec sleep 3600").run(by: .within(.milliseconds(200)))
            exit(waitpid(-1, nil, WNOHANG) == -1 && errno == ECHILD ? 0 : 1)
        }
    }

    /// A child that has exited can leave its streams open in something it started, and
    /// the end of a stream is what a reading waits for: the limit covers that wait too. The
    /// grandchild holds the streams for as long as the hang guard, so only a hang lets them
    /// end before the limit.
    @Test(.timeLimit(.minutes(2))) func aStreamHeldOpenPastTheChildsExitIsGivenUpOnAtTheLimit() throws {
        let overran = try #require(#expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", "sleep \(hangGuard.components.seconds) & exit 0").run(by: .within(.milliseconds(500)))
        })
        #expect(overran.limit == .milliseconds(500))
    }

    /// The limit is the reading's: a command run by a deadline that another has spent is
    /// not started, where a limit of its own would have run it.
    @Test(.timeLimit(.minutes(2))) func aCommandRunByADeadlineAnotherSpentIsNotStarted() throws {
        let marker = Self.marker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let deadline = Command.Deadline.within(.milliseconds(200))
        #expect(throws: Command.Overran.self) { try Command("/bin/sh", "-c", "exec sleep 3600").run(by: deadline) }
        let unstarted = #expect(throws: Command.Unstarted.self) { try Command("/usr/bin/touch", marker.path).run(by: deadline) }
        #expect(unstarted == Command.Unstarted(command: "touch \(marker.path)", limit: .milliseconds(200)))
        #expect(unstarted?.description == "`touch \(marker.path)` was not started: the limit of 0.2 seconds was spent before it")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A reading's limit and its cancel count from the call that asked for it, not from when
    /// the reading was given a thread: a reading cancelled while its queue is held, as a busy
    /// Mac holds one, starts no command once the queue lets it go. The limit is the same
    /// value as the stop, made at the same call, so a reading that made either later, when
    /// it got its thread, would hold a stop nobody pulled and run the command.
    @Test(.timeLimit(.minutes(2))) func aReadingCancelledWhileItWaitsForItsQueueStartsNoCommand() async throws {
        let marker = Self.marker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let queue = DispatchQueue(label: "CommandTests.held")
        let held = Latch()
        queue.async { try? held.waitOpen("the test to let the queue go") }
        let taken = Task {
            try await reading(within: .seconds(3600), on: queue) { deadline in
                Result { try Command("/usr/bin/touch", marker.path).run(by: deadline) }
            }
        }
        // Before the reading is asked for or after, the cancel lands while the queue is held.
        taken.cancel()
        held.open()
        // Thrown once the reading's work has run on the queue let go, which started nothing.
        await #expect(throws: CancellationError.self) { try await taken.value }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// A reading cancelled while a command runs ends at once, the command with it: thrown
    /// as a cancel, not as a command that failed or overran, and the child stopped and
    /// collected by the time it is thrown, as one given up on at its limit is. Its limit is
    /// past the test's, so only the cancel can end it in time.
    @Test(.timeLimit(.minutes(2))) func aReadingCancelledWhileACommandRunsEndsItAndLeavesNoChild() async throws {
        let handshake = try Handshake()
        defer { handshake.remove() }
        let taken = Task {
            try await reading(within: .seconds(3600)) { deadline in
                Result { try Command("/bin/sh", "-c", "\(handshake.said); exec sleep 3600").run(by: deadline) }
            }
        }
        let child = try handshake.pid("the command to start")
        taken.cancel()
        await #expect(throws: CancellationError.self) { try await taken.value }
        #expect(kill(child, 0) == -1 && errno == ESRCH)
    }

    /// A command given up on holds nothing open either: vhidd reads the driver every two
    /// seconds while it waits, and a stuck tool is stuck at every one of them. Both ways of
    /// overrunning: a child that never ends, whose streams end when it is stopped, and one
    /// that has ended and left its streams open in something it started, where giving up is
    /// all that lets go of them. That one holds them for as long as the hang guard.
    ///
    /// In a process of its own: the count is of every descriptor the process holds, and in
    /// the test process another test's open would be counted as this one's leak.
    @Test(.timeLimit(.minutes(2)), arguments: [
        ("exec sleep 3600", Duration.milliseconds(20), 50),
        ("sleep \(hangGuard.components.seconds) & exit 0", Duration.milliseconds(300), 10),
    ])
    func aCommandGivenUpOnHoldsNoDescriptorOpen(script: String, limit: Duration, runs: Int) async {
        await #expect(processExitsWith: .success) { [script, limit, runs] in
            let (overran, grew) = try onAThreadOfItsOwn {
                let before = try Self.descriptors()
                let overran = (0..<runs).count { _ in
                    do { _ = try Command("/bin/sh", "-c", script).run(by: .within(limit)); return false } catch { return error is Command.Overran }
                }
                return (overran, try Self.descriptors() - before)
            }
            guard overran == runs, grew < runs else {
                FileHandle.standardError.write(Data("\(overran) of \(runs) overran, and the descriptors grew by \(grew)\n".utf8))
                exit(1)
            }
        }
    }

    /// A stop stays pulled: no command a stopped reading runs after it is started, so a
    /// reading of several commands runs none past the one it stopped.
    @Test(.timeLimit(.minutes(2))) func aCommandRunByAStoppedReadingIsNeverStarted() throws {
        let marker = Self.marker()
        defer { try? FileManager.default.removeItem(at: marker) }
        let deadline = Command.Deadline.within(.seconds(30))
        deadline.stop.pull()
        for _ in 0..<2 {
            #expect(throws: CancellationError.self) { try Command("/usr/bin/touch", marker.path).run(by: deadline) }
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(deadline.stop.ended.isEmpty)
    }

    /// The descriptors this process holds. Listed, not probed slot by slot: the table's
    /// size is a limit, and where the limit is lifted there are more slots than a test has
    /// time to ask about.
    static func descriptors() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }

    static func marker() -> URL { FileManager.default.temporaryDirectory.appending(path: "vhid-started-\(UUID().uuidString)") }
}

/// `work`, run on a thread that never drains a pool, as vhidd's probe thread is.
private func onAThreadOfItsOwn<T: Sendable>(_ work: @escaping @Sendable () throws -> T) throws -> T {
    let done = Latch<Result<T, any Error>?>(nil)
    Thread.detachNewThread { done.update { $0 = Result { try work() } } }
    return try done.wait(for: "the thread's work") { $0 != nil }!.get()
}

import Foundation
import OwnThread
import Testing
@testable import DriverExtension

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
        let output = try Command("/bin/sh", "-c", order.map(Self.fill).joined(separator: "; ")).run(within: .seconds(30))
        #expect(output.status == 0)
        #expect(output.stdout == String(repeating: "o", count: Self.size))
        #expect(output.stderr == String(repeating: "e", count: Self.size))
    }

    @Test func theStatusAndBothStreamsSurviveAFailingCommand() throws {
        let output = try Command("/bin/sh", "-c", "echo out; echo err >&2; exit 3").run(within: .seconds(30))
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
        #expect(output.merged == "out\nerr")
    }

    /// A command that has returned holds nothing open, on a thread that never drains a
    /// pool as much as on one that does: vhidd runs the driver probe every two seconds
    /// from a thread that never returns, and four commands a probe each leaving two
    /// descriptors behind would be the whole table within the minute.
    ///
    /// The count is the process's, and other tests open descriptors of their own while
    /// this runs, so what is checked is that it did not grow by the 200 that 100 leaking
    /// runs leave.
    @Test(.timeLimit(.minutes(1))) func aCommandThatHasReturnedHoldsNoDescriptorOpen() throws {
        // Listed, not probed slot by slot: the table's size is a limit, and where the
        // limit is lifted there are more slots than a test has time to ask about.
        @Sendable func open() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var counted: Result<(ran: Int, grew: Int), any Error>?
        Thread.detachNewThread {
            counted = Result {
                let before = try open()
                let ran = (0..<100).count { _ in (try? Command("/usr/bin/true").run(within: .seconds(30)))?.status == 0 }
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
    @Test(.timeLimit(.minutes(1))) func aCommandThatNeverEndsIsStoppedAtItsLimitAndNamed() throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "vhid-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let began = ContinuousClock.now
        let overran = #expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", "echo $$ > \(pidFile.path); exec sleep 600").run(within: .milliseconds(500))
        }
        #expect(ContinuousClock.now - began < .seconds(10))
        #expect(overran == Command.Overran(command: "sh -c echo $$ > \(pidFile.path); exec sleep 600", limit: .milliseconds(500)))
        #expect(overran?.description == "`sh -c echo $$ > \(pidFile.path); exec sleep 600` had not ended after 0.5 seconds and was stopped")
        let pid = try #require(pid_t(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Signal 0 reaches a zombie as much as a running child, so this is the child both
        // stopped and collected. It is collected a moment after the kill, not with it.
        let deadline = ContinuousClock.now + .seconds(10)
        while kill(pid, 0) == 0, ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    /// A child that has exited can leave its streams open in something it started, and
    /// the end of a stream is what a reading waits for: the limit covers that wait too.
    @Test(.timeLimit(.minutes(1))) func aStreamHeldOpenPastTheChildsExitIsGivenUpOnAtTheLimit() throws {
        let began = ContinuousClock.now
        #expect(throws: Command.Overran.self) {
            try Command("/bin/sh", "-c", "sleep 5 & exit 0").run(within: .milliseconds(500))
        }
        #expect(ContinuousClock.now - began < .seconds(4))
    }

    /// A command given up on holds nothing open either: vhidd reads the driver every two
    /// seconds while it waits, and a stuck tool is stuck at every one of them.
    @Test(.timeLimit(.minutes(1))) func aCommandGivenUpOnHoldsNoDescriptorOpen() throws {
        @Sendable func open() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var counted: Result<(overran: Int, grew: Int), any Error>?
        Thread.detachNewThread {
            counted = Result {
                let before = try open()
                let overran = (0..<50).count { _ in
                    do { _ = try Command("/bin/sleep", "600").run(within: .milliseconds(20)); return false } catch { return error is Command.Overran }
                }
                return (overran, try open() - before)
            }
            done.signal()
        }
        done.wait()
        let (overran, grew) = try #require(counted).get()
        #expect(overran == 50)
        #expect(grew < 50)
    }
}

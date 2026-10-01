import Foundation
import OwnThread
import Testing
@testable import vhidd

/// The cursor is read by a child in the session in front, and a session that comes to the
/// front gets a child of its own. [LAW:behavior-not-structure]
@Suite(.ownThread) struct FrontCursorTests {

    private final class Reader: FrontCursor.Reader {
        let session: FrontCursor.Session
        let log: Log
        var fails = false
        init(_ session: FrontCursor.Session, _ log: Log) { self.session = session; self.log = log }
        func read() throws -> (x: Double, y: Double) {
            log.add("read in \(session.audit)")
            if fails { throw FrontCursor.NobodyInFront() }
            return (Double(session.audit), 1)
        }
        func stop() { log.add("stop \(session.audit)") }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private let bmf = FrontCursor.Session(audit: 100003, user: "bmf")
    private let loginWindow = FrontCursor.Session(audit: 100120, user: "root")

    @Test func aSessionComingToTheFrontIsReadByAChildOfItsOwn() throws {
        let log = Log()
        var front = bmf
        let cursor = FrontCursor(front: { front }, start: { log.add("start \($0.audit)"); return Reader($0, log) })
        #expect(try cursor.read() == (100003, 1))
        #expect(try cursor.read() == (100003, 1))
        front = loginWindow
        #expect(try cursor.read() == (100120, 1))
        #expect(log.all == ["start 100003", "read in 100003", "read in 100003", "stop 100003", "start 100120", "read in 100120"])
    }

    @Test func aReaderThatFailsIsStoppedAndTheNextReadStartsAnother() throws {
        let log = Log()
        var readers: [Reader] = []
        let cursor = FrontCursor(front: { bmf }, start: { let reader = Reader($0, log); readers.append(reader); return reader })
        _ = try cursor.read()
        readers[0].fails = true
        #expect(throws: FrontCursor.NobodyInFront.self) { try cursor.read() }
        #expect(try cursor.read() == (100003, 1))
        #expect(readers.count == 2)
        #expect(log.all == ["read in 100003", "read in 100003", "stop 100003", "read in 100003"])
    }

    @Test func nobodyInFrontIsSaidAndStartsNothing() {
        let cursor = FrontCursor(front: { throw FrontCursor.NobodyInFront() }, start: { _ in Issue.record("started a reader"); throw FrontCursor.NobodyInFront() })
        #expect(throws: FrontCursor.NobodyInFront.self) { try cursor.read() }
    }

    /// IOConsoleUsers as `ioreg` showed it on studious at the login window, bmf switched
    /// out behind it.
    @Test func theFrontSessionIsTheOneMarkedOnConsole() throws {
        let users: [[String: Any]] = [
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserNameKey": "root", "kCGSSessionAuditIDKey": NSNumber(value: 100120)],
            ["kCGSSessionOnConsoleKey": false, "kCGSSessionUserNameKey": "bmf", "kCGSSessionAuditIDKey": NSNumber(value: 100003)],
        ]
        #expect(try FrontCursor.frontSession(users) == loginWindow)
        #expect(throws: FrontCursor.NobodyInFront.self) { try FrontCursor.frontSession(Array(users.dropFirst())) }
        #expect(throws: FrontCursor.NobodyInFront.self) { try FrontCursor.frontSession([]) }
        #expect(throws: FrontCursor.Unnamed.self) { try FrontCursor.frontSession([["kCGSSessionOnConsoleKey": true]]) }
    }

    /// Long enough that no runner is slow enough to reach it: the limit on what a test does
    /// not test, there so a child that hangs fails the test and does not hang the run.
    /// [LAW:no-ambient-temporal-coupling] a test's verdict does not turn on how fast `sh` is.
    private static let unhurried: Duration = .seconds(30)

    /// A real child over real pipes, played by `sh`: what it says is what the read says.
    /// Each wait is unhurried but in the test of that wait. The script says `joined` itself,
    /// after whatever the test needs to be so by the time the reader is handed back.
    private func child(_ script: String, joinWithin: Duration = unhurried, patience: Duration = unhurried) throws -> ChildReader {
        try ChildReader(in: bmf, executable: "/bin/sh", arguments: ["-c", script], joinWithin: joinWithin, patience: patience)
    }

    @Test func aChildAnswersEachLineWithTheCursor() throws {
        let reader = try child("echo joined; while read _; do echo '12.5 40'; done")
        defer { reader.stop() }
        #expect(try reader.read() == (12.5, 40))
        #expect(try reader.read() == (12.5, 40))
    }

    @Test func aChildThatCouldNotJoinSaysWhy() {
        #expect {
            try child("echo 'could not join audit session 100003: errno 1'; exit 1")
        } throws: { "\($0)".contains("answered 'could not join audit session 100003: errno 1'") }
    }

    @Test func aChildThatNeverSaysItJoinedIsGivenUpOnAndEnded() {
        let began = ContinuousClock.now
        #expect {
            try child("trap '' TERM; sleep 30", joinWithin: .milliseconds(300))
        } throws: { "\($0)".contains("did not say it joined within 0.3 seconds") }
        // Returning at all means the child was reaped: `stop` waits for it.
        #expect(began.duration(to: .now) < .seconds(2))
    }

    @Test func aChildThatHasEndedFailsTheReadAndNotTheDaemon() throws {
        // The child closes its stdin before it says it joined, so the read is the write to
        // a closed pipe. Hearing the child end would not say so: a process that ends closes
        // its descriptors from the highest down, its stdout before its stdin.
        let reader = try child("exec 0<&-; echo joined")
        defer { reader.stop() }
        // The pipe is closed once nothing else holds its reading end, and a child being
        // started holds every descriptor its parent has until it has become its program:
        // `spawn` takes them from it then, not before. One that another test started
        // while this reader was is such a holder, the write reaches it, and the read
        // fails when it lets go. No holder can come after, the reading end being closed
        // here by then, so the reads that fail that way run out.
        // [LAW:no-ambient-temporal-coupling] Waited for by reading, not by a sleep.
        var failure: ChildReader.Failed?
        repeat {
            failure = #expect(throws: ChildReader.Failed.self) { try reader.read() }
        } while failure?.what == "ended before it could answer"
        // That write would raise SIGPIPE and end this test process.
        #expect(failure?.what == "could not be asked: errno \(EPIPE)")
    }

    /// Stopping returns only once the child is reaped, even one that ignores SIGTERM and
    /// never reads its stdin.
    @Test func stoppingEndsEvenAChildThatWillNotListen() throws {
        let reader = try child("trap '' TERM; exec 0<&-; echo joined; sleep 30")
        let began = ContinuousClock.now
        reader.stop()
        #expect(began.duration(to: .now) < .seconds(2))
    }

    @Test func aChildThatDoesNotAnswerIsGivenUpOnInTime() throws {
        let reader = try child("echo joined; sleep 30", patience: .milliseconds(300))
        defer { reader.stop() }
        let began = ContinuousClock.now
        #expect { try reader.read() } throws: { "\($0)".contains("did not answer within 0.3 seconds") }
        #expect(began.duration(to: .now) < .seconds(2))
    }

    @Test func theReaderFlagIsReadOnlyWithASession() {
        #expect(cursorReaderArgument(["vhidd", "--read-cursor-in", "100120"]) == 100120)
        #expect(cursorReaderArgument(["vhidd", "--read-cursor-in"]) == nil)
        #expect(cursorReaderArgument(["vhidd", "--service", "ai.promptctl.vhid"]) == nil)
    }

    /// The seat answers the read without taking the devices, and while they are down.
    @Test func aSeatReadsTheCursorWithoutTheDevices() {
        let holder = Holder()
        let seat = Seat(ObjectIdentifier(NSObject()), pid: 41, holder: holder, readiness: Readiness(driver: { .running }), cursor: FixedCursor(at: (7, 9)))
        var answer: (Double, Double, Error?)?
        seat.cursor { answer = ($0, $1, $2) }
        #expect(answer?.0 == 7 && answer?.1 == 9 && answer?.2 == nil)
        #expect(holder.pid(on: 1) == nil)
    }
}

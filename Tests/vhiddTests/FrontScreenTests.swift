import Foundation
import OwnThread
import Testing
@testable import vhidd

/// The screen is read by a child in the session in front, and a session that comes to the
/// front gets a child of its own. [LAW:behavior-not-structure]
@Suite(.ownThread) struct FrontScreenTests {

    private final class Reader: FrontScreen.Reader {
        let session: FrontScreen.Session
        let log: Log
        var fails = false
        init(_ session: FrontScreen.Session, _ log: Log) { self.session = session; self.log = log }
        func cursor() throws -> (x: Double, y: Double) {
            log.add("read in \(session.audit)")
            if fails { throw FrontScreen.NobodyInFront() }
            return (Double(session.audit), 1)
        }
        func displays() throws -> [CGRect] {
            log.add("displays in \(session.audit)")
            return [CGRect(x: 0, y: 0, width: Double(session.audit), height: 1)]
        }
        func stop() { log.add("stop \(session.audit)") }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
    }

    private let bmf = FrontScreen.Session(audit: 100003, user: "bmf")
    private let loginWindow = FrontScreen.Session(audit: 100120, user: "root")

    /// The displays are asked of the same child as the cursor: one reader per session.
    @Test func theDisplaysAreReadByTheFrontSessionsChild() throws {
        let log = Log()
        let screen = FrontScreen(front: { bmf }, start: { log.add("start \($0.audit)"); return Reader($0, log) })
        #expect(try screen.cursor() == (100003, 1))
        #expect(try screen.displays() == [CGRect(x: 0, y: 0, width: 100003, height: 1)])
        #expect(log.all == ["start 100003", "read in 100003", "displays in 100003"])
    }

    @Test func aSessionComingToTheFrontIsReadByAChildOfItsOwn() throws {
        let log = Log()
        var front = bmf
        let cursor = FrontScreen(front: { front }, start: { log.add("start \($0.audit)"); return Reader($0, log) })
        #expect(try cursor.cursor() == (100003, 1))
        #expect(try cursor.cursor() == (100003, 1))
        front = loginWindow
        #expect(try cursor.cursor() == (100120, 1))
        #expect(log.all == ["start 100003", "read in 100003", "read in 100003", "stop 100003", "start 100120", "read in 100120"])
    }

    @Test func aReaderThatFailsIsStoppedAndTheNextReadStartsAnother() throws {
        let log = Log()
        var readers: [Reader] = []
        let cursor = FrontScreen(front: { bmf }, start: { let reader = Reader($0, log); readers.append(reader); return reader })
        _ = try cursor.cursor()
        readers[0].fails = true
        #expect(throws: FrontScreen.NobodyInFront.self) { try cursor.cursor() }
        #expect(try cursor.cursor() == (100003, 1))
        #expect(readers.count == 2)
        #expect(log.all == ["read in 100003", "read in 100003", "stop 100003", "read in 100003"])
    }

    /// A reader that could not start is the daemon's failure as much as one that failed a
    /// read: kept for a client that asks after the fact, and the next read tries again.
    @Test func aReaderThatCouldNotStartIsTheLastFailure() throws {
        let replaced = RunningBuild.Replaced(path: "/\(UUID())/vhidd")
        var starts = 0
        let cursor = FrontScreen(front: { bmf }, start: { _ in starts += 1; throw replaced })
        #expect(throws: RunningBuild.Replaced.self) { try cursor.cursor() }
        #expect(lastFailure.current?.text == "the screen reader in bmf's session 100003 failed: \(replaced)")
        #expect(throws: RunningBuild.Replaced.self) { try cursor.cursor() }
        #expect(starts == 2)
    }

    @Test func nobodyInFrontIsSaidAndStartsNothing() {
        let cursor = FrontScreen(front: { throw FrontScreen.NobodyInFront() }, start: { _ in Issue.record("started a reader"); throw FrontScreen.NobodyInFront() })
        #expect(throws: FrontScreen.NobodyInFront.self) { try cursor.cursor() }
    }

    /// IOConsoleUsers as `ioreg` showed it on studious at the login window, bmf switched
    /// out behind it.
    @Test func theFrontSessionIsTheOneMarkedOnConsole() throws {
        let users: [[String: Any]] = [
            ["kCGSSessionOnConsoleKey": true, "kCGSSessionUserNameKey": "root", "kCGSSessionAuditIDKey": NSNumber(value: 100120)],
            ["kCGSSessionOnConsoleKey": false, "kCGSSessionUserNameKey": "bmf", "kCGSSessionAuditIDKey": NSNumber(value: 100003)],
        ]
        #expect(try FrontScreen.frontSession(users) == loginWindow)
        #expect(throws: FrontScreen.NobodyInFront.self) { try FrontScreen.frontSession(Array(users.dropFirst())) }
        #expect(throws: FrontScreen.NobodyInFront.self) { try FrontScreen.frontSession([]) }
        #expect(throws: FrontScreen.Unnamed.self) { try FrontScreen.frontSession([["kCGSSessionOnConsoleKey": true]]) }
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
        #expect(try reader.cursor() == (12.5, 40))
        #expect(try reader.cursor() == (12.5, 40))
    }

    /// Each question goes as its own line, and the answer to `displays` is every display's
    /// rectangle; an answer that is not one is the reader failing, saying what it heard.
    @Test func aChildAnswersEachQuestionByName() throws {
        let reader = try child("""
        echo joined; while read q; do case $q in cursor) echo '12.5 40';; displays) echo '0 0 1920 1080;1920 -200 1280 800';; *) echo nonsense;; esac; done
        """)
        defer { reader.stop() }
        #expect(try reader.displays() == [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: 1920, y: -200, width: 1280, height: 800)])
        #expect(try reader.cursor() == (12.5, 40))
        let garbled = try child("echo joined; while read _; do echo '0 0 1920'; done")
        defer { garbled.stop() }
        #expect { try garbled.displays() } throws: { "\($0)".contains("answered '0 0 1920'") }
    }

    /// `refused` is the window server declining, whichever question it answers.
    @Test func aChildSaysTheWindowServerRefused() throws {
        let reader = try child("echo joined; while read _; do echo refused; done")
        defer { reader.stop() }
        #expect { try reader.displays() } throws: { ($0 as? WindowServerRefused)?.question == .displays }
        #expect { try reader.cursor() } throws: { ($0 as? WindowServerRefused)?.question == .cursor }
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
            failure = #expect(throws: ChildReader.Failed.self) { try reader.cursor() }
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
        #expect { try reader.cursor() } throws: { "\($0)".contains("did not answer within 0.3 seconds") }
        #expect(began.duration(to: .now) < .seconds(2))
    }

    @Test func theReaderFlagIsReadOnlyWithASession() {
        #expect(screenReaderArgument(["vhidd", "--read-screen-in", "100120"]) == 100120)
        #expect(screenReaderArgument(["vhidd", "--read-screen-in"]) == nil)
        #expect(screenReaderArgument(["vhidd", "--service", "ai.promptctl.vhid"]) == nil)
    }

    /// The seat answers the read without taking the devices, and while they are down.
    @Test func aSeatReadsTheCursorWithoutTheDevices() {
        let holder = Holder()
        let seat = Seat(ObjectIdentifier(NSObject()), pid: 41, holder: holder, readiness: Readiness(driver: { .running }), screen: FixedScreen(at: (7, 9)))
        var answer: (Double, Double, Error?)?
        seat.cursor { answer = ($0, $1, $2) }
        #expect(answer?.0 == 7 && answer?.1 == 9 && answer?.2 == nil)
        #expect(holder.pid(on: 1) == nil)
    }

    /// The displays are answered the same way, four numbers each.
    @Test func aSeatReadsTheDisplaysWithoutTheDevices() {
        let holder = Holder()
        let seat = Seat(ObjectIdentifier(NSObject()), pid: 41, holder: holder, readiness: Readiness(driver: { .running }),
                        screen: FixedScreen(frames: [CGRect(x: 0, y: 0, width: 1920, height: 1080), CGRect(x: -1280, y: 0, width: 1280, height: 800)]))
        var answer: ([NSNumber], Error?)?
        seat.displays { answer = ($0, $1) }
        #expect(answer?.0.map(\.doubleValue) == [0, 0, 1920, 1080, -1280, 0, 1280, 800] && answer?.1 == nil)
        #expect(holder.pid(on: 1) == nil)
    }
}

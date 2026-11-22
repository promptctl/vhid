import Foundation
import OwnThread
import ScreenSpace
import ScreenSpaceTesting
import Testing
import Timeline
import Waiting
@testable import vhidd

/// The screen is read by a child in the session in front, and a session that comes to the
/// front gets a child of its own. [LAW:behavior-not-structure]
@Suite(.ownThread, .hangGuarded) struct FrontScreenTests {

    private final class Reader: FrontScreen.Reader {
        let session: FrontScreen.Session
        let log: Log
        var fails = false
        init(_ session: FrontScreen.Session, _ log: Log) { self.session = session; self.log = log }
        func cursor(by deadline: Deadline) throws -> (x: Double, y: Double) {
            log.add("read in \(session.audit)")
            if fails { throw FrontScreen.NobodyInFront() }
            return (Double(session.audit), 1)
        }
        func layout(by deadline: Deadline) throws -> DisplayLayout {
            log.add("layout in \(session.audit)")
            return .at([.at(0, 0, Double(session.audit), 1)])
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

    /// The layout is asked of the same child as the cursor: one reader per session.
    @Test func theLayoutIsReadByTheFrontSessionsChild() throws {
        let log = Log()
        let screen = FrontScreen(front: { bmf }, start: { session, _ in log.add("start \(session.audit)"); return Reader(session, log) }, failed: log.add)
        #expect(try screen.cursor(by: guarded()) == (100003, 1))
        #expect(try screen.layout(by: guarded()) == .at([.at(0, 0, 100003, 1)]))
        #expect(log.all == ["start 100003", "read in 100003", "layout in 100003"])
    }

    @Test func aSessionComingToTheFrontIsReadByAChildOfItsOwn() throws {
        let log = Log()
        var front = bmf
        let cursor = FrontScreen(front: { front }, start: { session, _ in log.add("start \(session.audit)"); return Reader(session, log) }, failed: log.add)
        #expect(try cursor.cursor(by: guarded()) == (100003, 1))
        #expect(try cursor.cursor(by: guarded()) == (100003, 1))
        front = loginWindow
        #expect(try cursor.cursor(by: guarded()) == (100120, 1))
        #expect(log.all == ["start 100003", "read in 100003", "read in 100003", "stop 100003", "start 100120", "read in 100120"])
    }

    @Test func aReaderThatFailsIsStoppedAndTheNextReadStartsAnother() throws {
        let log = Log()
        var readers: [Reader] = []
        let cursor = FrontScreen(front: { bmf }, start: { session, _ in let reader = Reader(session, log); readers.append(reader); return reader }, failed: log.add)
        _ = try cursor.cursor(by: guarded())
        readers[0].fails = true
        #expect(throws: FrontScreen.NobodyInFront.self) { try cursor.cursor(by: guarded()) }
        #expect(try cursor.cursor(by: guarded()) == (100003, 1))
        #expect(readers.count == 2)
        #expect(log.all == ["read in 100003", "read in 100003", "stop 100003",
                            "the screen reader in bmf's session 100003 failed: no session is in front to read the screen in",
                            "read in 100003"])
    }

    /// A reader that could not start is the daemon's failure as much as one that failed a
    /// read, and the next read tries again.
    @Test func aReaderThatCouldNotStartIsAFailure() throws {
        let log = Log()
        let cursor = FrontScreen(front: { bmf }, start: { session, _ in log.add("start \(session.audit)"); throw FrontScreen.NobodyInFront() }, failed: log.add)
        #expect(throws: FrontScreen.NobodyInFront.self) { try cursor.cursor(by: guarded()) }
        #expect(throws: FrontScreen.NobodyInFront.self) { try cursor.cursor(by: guarded()) }
        let failure = "the screen reader in bmf's session 100003 failed: no session is in front to read the screen in"
        #expect(log.all == ["start 100003", failure, "start 100003", failure])
    }

    @Test func nobodyInFrontIsSaidAndStartsNothing() {
        let cursor = FrontScreen(front: { throw FrontScreen.NobodyInFront() }, start: { _, _ in Issue.record("started a reader"); throw FrontScreen.NobodyInFront() }, failed: { _ in })
        #expect(throws: FrontScreen.NobodyInFront.self) { try cursor.cursor(by: guarded()) }
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

    /// The build the daemon is, in every test that starts a child.
    private let build = Build(cdhash: "c0de")

    /// A real child over real pipes, played by `sh`: what it says is what the read says.
    /// It joins by `deadline`, the one guard unless the join is what the test is of. The
    /// script says `joined c0de` itself, after whatever the test needs to be so by the time
    /// the reader is handed back.
    private func child(_ script: String, joiningBy deadline: Deadline = guarded()) throws -> ChildReader {
        try ChildReader(in: bmf, executable: "/bin/sh", arguments: ["-c", script], build: build, by: deadline)
    }

    @Test func aChildAnswersEachLineWithTheCursor() throws {
        let reader = try child("echo joined c0de; while read _; do echo '12.5 40'; done")
        defer { reader.stop() }
        #expect(try reader.cursor(by: guarded()) == (12.5, 40))
        #expect(try reader.cursor(by: guarded()) == (12.5, 40))
    }

    /// Each question goes as its own line, and the answer to `layout` is the layout's record;
    /// an answer that is not one is the reader failing, saying what it heard and why.
    @Test func aChildAnswersEachQuestionByName() throws {
        let reader = try child("""
        echo joined c0de; while read q; do case $q in cursor) echo '12.5 40';; layout) echo '1 0 0 1920 1080 1 2 1920 -200 1280 800 0';; *) echo nonsense;; esac; done
        """)
        defer { reader.stop() }
        #expect(try reader.layout(by: guarded()) == .at([.at(0, 0, 1920, 1080), .at(1920, -200, 1280, 800)], asleep: [1]))
        #expect(try reader.cursor(by: guarded()) == (12.5, 40))
        let garbled = try child("echo joined c0de; while read _; do echo '1 0 0 1920'; done")
        defer { garbled.stop() }
        #expect { try garbled.layout(by: guarded()) } throws: { "\($0)".contains("answered '1 0 0 1920': the display layout record is not one this build reads") }
    }

    /// `refused` and why is the child unable to read what it was asked, whichever question it
    /// answers, and the why reaches the refusal.
    @Test func aChildSaysWhyItCouldNotRead() throws {
        let reader = try child("echo joined c0de; while read q; do echo \"refused $q went wrong\"; done")
        defer { reader.stop() }
        #expect { try reader.layout(by: guarded()) } throws: { ($0 as? WindowServerRefused).map { $0.question == .layout && $0.why == "layout went wrong" } == true }
        #expect { try reader.cursor(by: guarded()) } throws: { ($0 as? WindowServerRefused).map { $0.question == .cursor && $0.why == "cursor went wrong" } == true }
    }

    @Test func aChildThatCouldNotJoinSaysWhy() {
        #expect {
            try child("echo 'could not join audit session 100003: errno 1'; exit 1")
        } throws: { "\($0)".contains("answered 'could not join audit session 100003: errno 1'") }
    }

    /// A child of another build is refused at the join, saying the file it was started from
    /// was replaced: not asked anything, since the two need not speak one protocol.
    @Test func aChildOfAnotherBuildIsRefusedSayingTheFileWasReplaced() {
        let refusal = #expect(throws: ChildReader.AnotherBuild.self) { try child("echo joined f00d; while read _; do echo '12.5 40'; done") }
        #expect(refusal.map { "\($0)" } == "the reader in bmf's session 100003 said 'joined f00d', and this vhidd is build c0de: /bin/sh has been replaced by another build since vhidd started, and every reader started from it is that build: restart vhidd")
    }

    /// A build from before readers said their build says only `joined`, and is another build.
    @Test func aChildThatJoinsWithoutABuildIsAnotherBuild() {
        #expect(throws: ChildReader.AnotherBuild.self) { try child("echo joined; while read _; do echo '12.5 40'; done") }
    }

    /// The child sleeps past the test's whole limit, so returning at all means it was
    /// ended and reaped: `stop` waits for it. [LAW:verifiable-goals]
    @Test func aChildThatNeverSaysItJoinedIsGivenUpOnAndEnded() {
        #expect {
            try child("trap '' TERM; sleep 600", joiningBy: Timeline.suspending.deadline(within: .milliseconds(300)))
        } throws: { "\($0)".contains("did not say it joined by the limit of 0.3 seconds") }
    }

    @Test func aChildThatHasEndedFailsTheReadAndNotTheDaemon() throws {
        // The child closes its stdin before it says it joined, so the read is the write to
        // a closed pipe. Hearing the child end would not say so: a process that ends closes
        // its descriptors from the highest down, its stdout before its stdin.
        let reader = try child("exec 0<&-; echo joined c0de")
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
            failure = #expect(throws: ChildReader.Failed.self) { try reader.cursor(by: guarded()) }
        } while failure?.what == "ended before it could answer"
        // That write would raise SIGPIPE and end this test process.
        #expect(failure?.what == "could not be asked: errno \(EPIPE)")
    }

    /// Stopping returns only once the child is reaped, even one that ignores SIGTERM and
    /// never reads its stdin. The child sleeps past the test's whole limit, so stopping that
    /// returns at all ended it.
    @Test func stoppingEndsEvenAChildThatWillNotListen() throws {
        let reader = try child("trap '' TERM; exec 0<&-; echo joined c0de; sleep 600")
        reader.stop()
    }

    /// A child that cannot answer is given up on by the read's deadline, and sleeps past the
    /// test's whole limit, so the read returning at all is the give-up.
    @Test func aChildThatDoesNotAnswerIsGivenUpOnByTheReadsDeadline() throws {
        let reader = try child("echo joined c0de; sleep 600")
        defer { reader.stop() }
        #expect { try reader.cursor(by: Timeline.suspending.deadline(within: .milliseconds(300))) } throws: { "\($0)".contains("did not answer by the limit of 0.3 seconds") }
    }

    @Test func theReaderFlagIsReadOnlyWithASession() {
        #expect(screenReaderArgument(["vhidd", "--read-screen-in", "100120"]) == 100120)
        #expect(screenReaderArgument(["vhidd", "--read-screen-in"]) == nil)
        #expect(screenReaderArgument(["vhidd", "--service", "ai.promptctl.vhid"]) == nil)
    }

    /// The seat answers the read without taking the devices, and while they are down.
    @Test func aSeatReadsTheCursorWithoutTheDevices() {
        let holder = Holder()
        let seat = Seat(ObjectIdentifier(NSObject()), pid: 41, holder: holder, readiness: Readiness(driver: { _ in .running }), screen: FixedScreen(at: (7, 9)), timeline: .suspending)
        var answer: (Double, Double, Error?)?
        seat.cursor { answer = ($0, $1, $2) }
        #expect(answer?.0 == 7 && answer?.1 == 9 && answer?.2 == nil)
        #expect(holder.pid(on: 1) == nil)
    }

    /// The layout is answered the same way, as its record.
    @Test func aSeatReadsTheLayoutWithoutTheDevices() {
        let holder = Holder()
        let layout = DisplayLayout.at([.at(0, 0, 1920, 1080), .at(-1280, 0, 1280, 800)], asleep: [1])
        let seat = Seat(ObjectIdentifier(NSObject()), pid: 41, holder: holder, readiness: Readiness(driver: { _ in .running }), screen: FixedScreen(displays: layout), timeline: .suspending)
        var answer: ([NSNumber], Error?)?
        seat.layout { answer = ($0, $1) }
        #expect(answer?.0.map(\.doubleValue) == layout.record && answer?.1 == nil)
        #expect(holder.pid(on: 1) == nil)
    }
}

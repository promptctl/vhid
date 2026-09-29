import Foundation
import Testing
@testable import vhidd

/// The cursor is read by a child in the session in front, and a session that comes to the
/// front gets a child of its own. [LAW:behavior-not-structure]
@Suite struct FrontCursorTests {

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
    }

    @Test func theReaderFlagIsReadOnlyWithASession() {
        #expect(cursorReaderArgument(["vhidd", "--read-cursor-in", "100120"]) == 100120)
        #expect(cursorReaderArgument(["vhidd", "--read-cursor-in"]) == nil)
        #expect(cursorReaderArgument(["vhidd", "--service", "ai.promptctl.vhid"]) == nil)
    }

    /// The seat answers the read without taking the devices, and while they are down.
    @Test func aSeatReadsTheCursorWithoutTheDevices() {
        let holder = Holder()
        let seat = Seat(ObjectIdentifier(NSObject()), pid: 41, holder: holder, readiness: Readiness(), cursor: FixedCursor(at: (7, 9)))
        var answer: (Double, Double, Error?)?
        seat.cursor { answer = ($0, $1, $2) }
        #expect(answer?.0 == 7 && answer?.1 == 9 && answer?.2 == nil)
        #expect(holder.pid(on: 1) == nil)
    }
}

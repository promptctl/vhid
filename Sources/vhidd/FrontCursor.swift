import Foundation
import IOKit

/// Where the cursor is, read in the session in front, whoever's it is.
///
/// **Only a process in the session in front reads the cursor.** Anywhere else the window
/// server answers (0, 0) as though it were a position, not an error: an SSH caller at the
/// login window, `sudo`, and `launchctl asuser` into the wrong user all read it. Measured
/// on studious, macOS 15.0.1, at the login window after fast user switching: a root
/// process that joined the audit session IOConsoleUsers marks on console read the real
/// position, and one that joined bmf's session in the background read (0, 0).
///
/// **A process is its first session's for good.** One that read in the session in front,
/// joined another and read again kept answering from the first. So the read is not made
/// here, in the daemon, but in a child that joins the session in front before its first
/// read, and when another session comes to the front, a new child reads for it.
/// [LAW:no-ambient-temporal-coupling] Which session is in front is asked on every read, so
/// the child that answers is always the front one's.
///
/// Reads are serialized: one child, one line in and one line out at a time.
final class FrontCursor: CursorSource, @unchecked Sendable {
    /// A console session, as IOConsoleUsers names it.
    struct Session: Hashable, CustomStringConvertible {
        let audit: au_asid_t
        let user: String

        var description: String { "\(user)'s session \(audit)" }
    }

    /// Something that reads the cursor in one session, until it is stopped.
    protocol Reader: AnyObject {
        func read() throws -> (x: Double, y: Double)
        func stop()
    }

    private let front: () throws -> Session
    private let start: (Session) throws -> any Reader
    private let lock = NSLock()
    private var reading: (session: Session, reader: any Reader)?

    /// `front` says which session is in front; `start` makes a reader in one.
    /// [LAW:effects-at-boundaries] Both are handed in, so which child answers which read
    /// is a test and not a session switch on a real Mac.
    init(front: @escaping () throws -> Session, start: @escaping (Session) throws -> any Reader) {
        self.front = front
        self.start = start
    }

    /// Over the console this Mac has, with children of this very executable.
    static let real = FrontCursor(front: { try frontSession(consoleUsers()) }, start: { try ChildReader(in: $0) })

    func read() throws -> (x: Double, y: Double) {
        lock.lock(); defer { lock.unlock() }
        let session = try front()
        let reader = try reader(for: session)
        do {
            return try reader.read()
        } catch {
            // A reader that failed once is not asked again: the next read starts another.
            reader.stop()
            reading = nil
            logFailure("the cursor reader in \(session) failed: \(error)")
            throw error
        }
    }

    /// The reader for `session`, the one already running when it is that session's.
    private func reader(for session: Session) throws -> any Reader {
        if let reading, reading.session == session { return reading.reader }
        reading?.reader.stop()
        reading = nil
        let reader = try start(session)
        log("reading the cursor in \(session)")
        reading = (session, reader)
        return reader
    }

    /// No session is marked on console: between one user leaving and the next arriving.
    struct NobodyInFront: Error, CustomStringConvertible {
        var description: String { "no session is in front to read the cursor in" }
    }

    /// [LAW:parse-dont-validate] The session IOConsoleUsers marks on console, or why none.
    static func frontSession(_ users: [[String: Any]]) throws -> Session {
        guard let user = users.first(where: { $0["kCGSSessionOnConsoleKey"] as? Bool == true }),
              let audit = (user["kCGSSessionAuditIDKey"] as? NSNumber)?.int32Value,
              let name = user["kCGSSessionUserNameKey"] as? String
        else { throw NobodyInFront() }
        return Session(audit: audit, user: name)
    }

    /// The console sessions, from the registry's root, as `ioreg -n Root -d1` shows them.
    static func consoleUsers() throws -> [[String: Any]] {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return users as? [[String: Any]] ?? []
    }
}

/// Where the cursor is, as the daemon answers it.
protocol CursorSource: Sendable {
    func read() throws -> (x: Double, y: Double)
}

/// This executable, run as `--read-cursor-in <audit session>`: a child in the session in
/// front, answering one line with the cursor for each line it is sent.
final class ChildReader: FrontCursor.Reader {
    private let process = Process()
    private let requests = Pipe()
    private let answers = Pipe()
    private let session: FrontCursor.Session

    init(in session: FrontCursor.Session) throws {
        self.session = session
        process.executableURL = Bundle.main.executableURL
        process.arguments = [cursorReaderFlag, String(session.audit)]
        process.standardInput = requests
        process.standardOutput = answers
        try process.run()
    }

    struct Failed: Error, CustomStringConvertible {
        let session: FrontCursor.Session
        let answer: String?
        var description: String {
            answer.map { "the reader in \(session) answered '\($0)'" } ?? "the reader in \(session) ended without answering"
        }
    }

    func read() throws -> (x: Double, y: Double) {
        try requests.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        let line = try answerLine()
        let fields = line.split(separator: " ").compactMap { Double($0) }
        guard fields.count == 2 else { throw Failed(session: session, answer: line) }
        return (fields[0], fields[1])
    }

    /// One line from the child, read a byte at a time so nothing past it is taken.
    private func answerLine() throws -> String {
        var bytes: [UInt8] = []
        while true {
            guard let byte = try answers.fileHandleForReading.read(upToCount: 1)?.first else {
                throw Failed(session: session, answer: nil)
            }
            if byte == UInt8(ascii: "\n") { return String(decoding: bytes, as: UTF8.self) }
            bytes.append(byte)
        }
    }

    func stop() {
        try? requests.fileHandleForWriting.close()
        process.terminate()
    }
}

/// The flag that makes this executable a cursor reader rather than the daemon.
let cursorReaderFlag = "--read-cursor-in"

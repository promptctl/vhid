import Children
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

    /// A session is marked on console but does not say whose it is or which it is.
    struct Unnamed: Error, CustomStringConvertible {
        let entry: String
        var description: String { "the session in front has no user name or audit id in IOConsoleUsers: \(entry)" }
    }

    /// [LAW:parse-dont-validate] The session IOConsoleUsers marks on console, or why none.
    static func frontSession(_ users: [[String: Any]]) throws -> Session {
        guard let user = users.first(where: { $0["kCGSSessionOnConsoleKey"] as? Bool == true }) else { throw NobodyInFront() }
        guard let audit = (user["kCGSSessionAuditIDKey"] as? NSNumber)?.int32Value,
              let name = user["kCGSSessionUserNameKey"] as? String
        else { throw Unnamed(entry: "\(user)") }
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
/// front, saying first whether it joined, then answering one line with the cursor for each
/// line it is sent.
final class ChildReader: FrontCursor.Reader {
    private let pid: pid_t
    /// The child's stdin and stdout, from this side.
    private let requests: Int32
    private let answers: Int32
    private let session: FrontCursor.Session
    private let patience: Duration
    /// Bytes read past the last whole line; a read may hand back less than a line.
    private var pending: [UInt8] = []

    /// `patience` is how long one answer may take: well under the client's own wait, so a
    /// child stuck in the window server is ended and replaced while the client is still
    /// listening, and the lock `FrontCursor` holds across the read is never held forever.
    ///
    /// Waits for the child's first line, which says whether it joined `session`: read
    /// before anything is written to it, so a child that could not join and ended is heard
    /// saying why, and not taken for a broken pipe. [LAW:no-ambient-temporal-coupling]
    init(in session: FrontCursor.Session, executable: String, arguments: [String], patience: Duration = .seconds(1)) throws {
        self.session = session
        self.patience = patience
        var stdin: [Int32] = [0, 0], stdout: [Int32] = [0, 0]
        guard pipe(&stdin) == 0 else { throw Failed(session: session, what: "could not be given a pipe: errno \(errno)") }
        guard pipe(&stdout) == 0 else {
            close(stdin[0]); close(stdin[1])
            throw Failed(session: session, what: "could not be given a pipe: errno \(errno)")
        }
        requests = stdin[1]
        answers = stdout[0]
        defer { close(stdin[0]); close(stdout[1]) }
        do {
            // A child that has ended must fail the write, not raise SIGPIPE in the daemon.
            // [LAW:no-silent-failure] SIGPIPE ends vhidd without a word, holding what it held.
            guard fcntl(requests, F_SETNOSIGPIPE, 1) == 0 else { throw Failed(session: session, what: "could not refuse SIGPIPE: errno \(errno)") }
            pid = try spawn(executable, arguments, stdio: [0: stdin[0], 1: stdout[1]])
        } catch {
            close(requests); close(answers)
            throw error
        }
        do {
            let joined = try answerLine(by: .now + patience)
            guard joined == joinedAnswer else { throw Failed(session: session, what: "answered '\(joined)'") }
        } catch {
            stop()
            throw error
        }
    }

    /// This very executable, reading in `session`.
    convenience init(in session: FrontCursor.Session) throws {
        try self.init(in: session, executable: Bundle.main.executablePath!, arguments: [cursorReaderFlag, String(session.audit)])
    }

    struct Failed: Error, CustomStringConvertible {
        let session: FrontCursor.Session
        let what: String
        var description: String { "the reader in \(session) \(what)" }
    }

    func read() throws -> (x: Double, y: Double) {
        guard Darwin.write(requests, "\n", 1) == 1 else { throw Failed(session: session, what: "could not be asked: errno \(errno)") }
        let line = try answerLine(by: .now + patience)
        let fields = line.split(separator: " ").compactMap { Double($0) }
        guard fields.count == 2 else { throw Failed(session: session, what: "answered '\(line)'") }
        return (fields[0], fields[1])
    }

    /// One line from the child, or `Failed` once `deadline` passes or the child ends.
    private func answerLine(by deadline: ContinuousClock.Instant) throws -> String {
        while true {
            if let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                defer { pending.removeSubrange(...newline) }
                return String(decoding: pending[..<newline], as: UTF8.self)
            }
            let left = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = Int32(clamping: max(0, left.seconds * 1000 + left.attoseconds / 1_000_000_000_000_000))
            var poll = pollfd(fd: answers, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&poll, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw Failed(session: session, what: "could not be heard: errno \(errno)") }
            guard ready > 0 else { throw Failed(session: session, what: "did not answer within \(patience)") }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(answers, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failed(session: session, what: "could not be heard: errno \(errno)") }
            guard count > 0 else { throw Failed(session: session, what: "ended without answering") }
            pending += buffer.prefix(count)
        }
    }

    /// Ends the child and reaps it. SIGKILL, since a child stuck in the window server may
    /// never read the closed stdin; safe by pid, since an unreaped child's pid is its own.
    func stop() {
        close(requests)
        close(answers)
        kill(pid, SIGKILL)
        waitpid(pid, nil, 0)
    }
}

/// What a reader says first when it has joined its session.
let joinedAnswer = "joined"

/// The flag that makes this executable a cursor reader rather than the daemon.
let cursorReaderFlag = "--read-cursor-in"

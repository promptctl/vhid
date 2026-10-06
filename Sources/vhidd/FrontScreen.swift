import ChildProcess
import CoreGraphics
import Foundation
import IOKit

/// Where the cursor is and where the displays are, read in the session in front, whoever's
/// it is.
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
/// **The displays are read there for the same reason.** They are the session's screen as
/// much as the cursor is, and a client that read them for itself would read its own
/// session's, or none at the login window.
///
/// Reads are serialized: one child, one line in and one line out at a time.
final class FrontScreen: ScreenSource, @unchecked Sendable {
    /// A console session, as IOConsoleUsers names it.
    struct Session: Hashable, CustomStringConvertible {
        let audit: au_asid_t
        let user: String

        var description: String { "\(user)'s session \(audit)" }
    }

    /// Something that reads the screen in one session, until it is stopped.
    protocol Reader: AnyObject {
        func cursor() throws -> (x: Double, y: Double)
        func displays() throws -> [CGRect]
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
    static let real = FrontScreen(front: { try frontSession(consoleUsers()) }, start: { try ChildReader(in: $0) })

    func cursor() throws -> (x: Double, y: Double) { try read { try $0.cursor() } }

    func displays() throws -> [CGRect] { try read { try $0.displays() } }

    /// `question` asked of the front session's reader.
    private func read<Answer>(_ question: (any Reader) throws -> Answer) throws -> Answer {
        lock.lock(); defer { lock.unlock() }
        let session = try front()
        // [LAW:nothing-unseen] A reader that could not start is logged as one that failed
        // a question is: either way the client hears it, and only the log keeps it.
        do {
            let reader = try reader(for: session)
            do {
                return try question(reader)
            } catch {
                // A reader that failed once is not asked again: the next read starts another.
                // A refusal included, since a child tied to its session cannot tell a window
                // server that declined once from a connection to it that will never answer.
                reader.stop()
                reading = nil
                throw error
            }
        } catch {
            logFailure("the screen reader in \(session) failed: \(error)")
            throw error
        }
    }

    /// The reader for `session`, the one already running when it is that session's.
    private func reader(for session: Session) throws -> any Reader {
        if let reading, reading.session == session { return reading.reader }
        reading?.reader.stop()
        reading = nil
        let reader = try start(session)
        log("reading the screen in \(session)")
        reading = (session, reader)
        return reader
    }

    /// No session is marked on console: between one user leaving and the next arriving.
    struct NobodyInFront: Error, CustomStringConvertible {
        var description: String { "no session is in front to read the screen in" }
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

/// A reader that answered, saying the window server in its session would not: told apart
/// from a reader that failed so the log names the window server.
struct WindowServerRefused: Error, CustomStringConvertible {
    let session: FrontScreen.Session
    let question: ScreenQuestion
    var description: String { "the window server in \(session) would not answer '\(question.rawValue)'" }
}

/// Where the cursor is and where the displays are, as the daemon answers them.
protocol ScreenSource: Sendable {
    func cursor() throws -> (x: Double, y: Double)
    func displays() throws -> [CGRect]
}

/// This executable, run as `--read-screen-in <audit session>`: a child in the session in
/// front, saying first whether it joined, then answering each question it is sent with a
/// line.
final class ChildReader: FrontScreen.Reader {
    private let pid: pid_t
    /// The child's stdin and stdout, from this side.
    private let requests: Int32
    private let answers: Int32
    private let session: FrontScreen.Session
    private let patience: Duration
    /// Bytes read past the last whole line; a read may hand back less than a line.
    private var pending: [UInt8] = []

    /// `patience` is how long one answer may take: well under the client's own wait, so a
    /// child stuck in the window server is ended and replaced while the client is still
    /// listening, and the lock `FrontScreen` holds across the read is never held forever.
    ///
    /// Waits for the child's first line, which says whether it joined `session`: read
    /// before anything is written to it, so a child that could not join and ended is heard
    /// saying why, and not taken for a broken pipe. [LAW:no-ambient-temporal-coupling]
    /// `joinWithin` is how long that first line may take. It is a limit of its own because
    /// it covers the child being started, which an answer does not.
    init(in session: FrontScreen.Session, executable: String, arguments: [String], joinWithin: Duration = .seconds(1), patience: Duration = .seconds(1)) throws {
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
            let joined = try answerLine(within: joinWithin, to: "say it joined")
            guard joined == joinedAnswer else { throw Failed(session: session, what: "answered '\(joined)'") }
        } catch {
            stop()
            throw error
        }
    }

    /// This very executable, reading in `session`: this build, or none.
    convenience init(in session: FrontScreen.Session) throws {
        try self.init(in: session, executable: RunningBuild.executable(), arguments: [screenReaderFlag, String(session.audit)])
    }

    struct Failed: Error, CustomStringConvertible {
        let session: FrontScreen.Session
        let what: String
        var description: String { "the reader in \(session) \(what)" }
    }

    func cursor() throws -> (x: Double, y: Double) {
        let line = try ask(.cursor)
        guard let fields = Self.numbers(line), fields.count == 2 else { throw Failed(session: session, what: "answered '\(line)'") }
        return (fields[0], fields[1])
    }

    func displays() throws -> [CGRect] {
        let line = try ask(.displays)
        return try line.split(separator: ";").map { frame in
            guard let fields = Self.numbers(frame), fields.count == 4 else { throw Failed(session: session, what: "answered '\(line)'") }
            return CGRect(x: fields[0], y: fields[1], width: fields[2], height: fields[3])
        }
    }

    /// `question` sent as its line, and the line answering it: `WindowServerRefused` when
    /// the child says the window server would not answer.
    private func ask(_ question: ScreenQuestion) throws -> String {
        let line = question.rawValue + "\n"
        guard Darwin.write(requests, line, line.utf8.count) == line.utf8.count else { throw Failed(session: session, what: "could not be asked: errno \(errno)") }
        let answer = try answerLine(within: patience, to: "answer")
        guard answer != refusedAnswer else { throw WindowServerRefused(session: session, question: question) }
        return answer
    }

    /// The space-separated numbers in `text`, or nil when any of it is not one.
    private static func numbers(_ text: some StringProtocol) -> [Double]? {
        let fields = text.split(separator: " ")
        let numbers = fields.compactMap { Double($0) }
        return numbers.count == fields.count ? numbers : nil
    }

    /// One line from the child, or `Failed` once `limit` has passed or the child ends.
    /// `what` is what the child does by sending it, so a failure says which wait it was.
    /// [LAW:nothing-unseen] A child that never started and one stuck in the window server
    /// are told apart by what the daemon says of them.
    private func answerLine(within limit: Duration, to what: String) throws -> String {
        let deadline = ContinuousClock.now + limit
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
            guard ready > 0 else { throw Failed(session: session, what: "did not \(what) within \(limit)") }
            var buffer = [UInt8](repeating: 0, count: 256)
            let count = Darwin.read(answers, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw Failed(session: session, what: "could not be heard: errno \(errno)") }
            guard count > 0 else { throw Failed(session: session, what: "ended before it could \(what)") }
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

/// The flag that makes this executable a screen reader rather than the daemon.
let screenReaderFlag = "--read-screen-in"

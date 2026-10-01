import ChildProcess
import Foundation

/// One command run against the machine, and everything it said.
///
/// Small on purpose: a reading needs a status and two streams, and a general process
/// wrapper would be a second thing to maintain for the sake of arguments nobody passes.
/// It lives beside the driver probe because that is where the first reading was taken;
/// `vhid doctor`'s launchd reading is taken the same way rather than growing a second
/// runner.
public struct Command {
    public let tool: URL
    public let arguments: [String]

    public init(_ tool: String, _ arguments: String...) {
        self.tool = URL(fileURLWithPath: tool)
        self.arguments = arguments
    }

    public struct Output {
        public let status: Int32
        public let stdout: String
        public let stderr: String

        public init(status: Int32, stdout: String, stderr: String) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
        /// What a reader should be shown when the command failed: tools split their
        /// complaints across both streams and which one carried it is not the reader's
        /// problem.
        public var merged: String {
            [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    /// How long a command is given where a person or a script is what waits for it. The
    /// tools answer in hundredths of a second, so this is far past a tool that is going to
    /// answer, on a Mac however busy, and it is still an end. vhidd reads for a client who
    /// waits less, and has a limit of its own.
    public static let limit: Duration = .seconds(30)

    /// When a reading is to be over, and the limit that put it there.
    ///
    /// [LAW:no-ambient-temporal-coupling] One is made for a reading and handed to every
    /// command the reading runs, so the limit is the reading's: each command is given what
    /// the ones before it left, where a limit apiece would add up to several.
    ///
    /// On the clock that stops with the Mac: a child does not run while the Mac sleeps, and
    /// a limit that counted the sleep would be past on waking for a tool that had run a
    /// moment of it.
    public struct Deadline: Sendable {
        public let limit: Duration
        fileprivate let at: SuspendingClock.Instant

        /// Over `limit` from now.
        public static func within(_ limit: Duration) -> Deadline {
            Deadline(limit: limit, at: .now + limit)
        }
    }

    /// A command that had not ended at its deadline: the child still running, or a stream
    /// of it still open in something the child started.
    ///
    /// `ran` is how long this command had, to the millisecond, beside the limit of the
    /// reading it was run for: the command a reading's limit ends on is the one running
    /// then, and may have had a moment of it where one before it had the rest.
    public struct Overran: Error, CustomStringConvertible, Equatable {
        public let command: String
        public let ran: Duration
        public let limit: Duration

        public var description: String { "`\(command)` had not ended \(ran) after it was started, at the limit of \(limit), and was given up on" }
    }

    /// A command this Mac would not let be heard to its end: no pipe for it, no watch on
    /// it, or no status from it.
    public struct Unheard: Error, CustomStringConvertible, Equatable {
        public let command: String
        public let what: String
        public let code: Int32

        public var description: String { "`\(command)` \(what): \(String(cString: strerror(code))) (\(code))" }
    }

    /// The command as a person would have typed it, for the errors that name it.
    private var said: String { ([tool.lastPathComponent] + arguments).joined(separator: " ") }

    /// `code` is errno as the call is made, read before `said` runs anything that could
    /// set it to something else.
    private func unheard(_ what: String, _ code: Int32 = errno) -> Unheard { Unheard(command: said, what: what, code: code) }

    /// Runs the command to its end, or to `deadline`, where it is given up on and thrown as
    /// `Overran`. [LAW:types-are-the-program] The deadline is not optional, so nothing this
    /// program runs can hold its caller for good.
    ///
    /// The child is this call's from `spawn` to `collect`: nothing of it is left once this
    /// returns or throws, not a descriptor and not a pid to collect.
    public func run(by deadline: Deadline) throws -> Output {
        let started = SuspendingClock.now
        let out = try pipe()
        let err: (read: Int32, write: Int32)
        do { err = try pipe() } catch {
            close(out.read); close(out.write)
            throw error
        }
        defer { close(out.read); close(err.read) }
        let pid: pid_t
        do {
            // The writing ends are the child's once it has them: one left open here is a
            // stream that never ends.
            defer { close(out.write); close(err.write) }
            pid = try spawn(tool.path, arguments, stdio: [1: out.write, 2: err.write])
        }
        let heard = Result { try hear(pid, [out.read, err.read], by: deadline) }
        // [LAW:single-enforcer] The one place the child is stopped and collected, however
        // the hearing ended. What it started is not reached: a stream held open past the
        // child's exit is let go of here and goes on being held there. SIGKILL, because a
        // tool that is stuck may not be answering SIGTERM, and with no look at whether the
        // child still runs: the pid is this call's until the line below collects it, so
        // the signal reaches the child or, where it has ended, nothing. The wait after it
        // has no limit of its own: it is for the kernel to end a child that has been
        // killed, and one given up on would be a pid nobody collects.
        // [LAW:dataflow-not-control-flow]
        kill(pid, SIGKILL)
        let ending: Ending
        do throws(Uncollected) { ending = try collect(pid) } catch { throw unheard("could not be collected", error.code) }
        guard let streams = try heard.get() else {
            let ran = SuspendingClock.now - started
            throw Overran(
                command: said,
                ran: .milliseconds(ran.components.seconds * 1000 + ran.components.attoseconds / 1_000_000_000_000_000),
                limit: deadline.limit
            )
        }
        // What it exited with, or the signal that ended it.
        let status = switch ending { case .exited(let code), .signalled(let code): code }
        return Output(
            status: status,
            stdout: String(decoding: streams[out.read, default: []], as: UTF8.self),
            stderr: String(decoding: streams[err.read, default: []], as: UTF8.self)
        )
    }

    private func pipe() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard Darwin.pipe(&ends) == 0 else { throw unheard("could not be given a pipe") }
        return (ends[0], ends[1])
    }

    /// Everything each of `streams` carried, once the child has exited and every stream
    /// has ended, or nil where `deadline` came first.
    ///
    /// The exit and the streams are waited for at once, on one queue. A child whose pipe
    /// fills blocks in `write(2)` until someone reads it, so a stream that waits its turn
    /// is a stream whose turn can never come: the child cannot reach the exit that would
    /// end the read being waited on. [LAW:no-ambient-temporal-coupling] Watching all of it
    /// from the start leaves no order to get wrong.
    private func hear(_ pid: pid_t, _ streams: [Int32], by deadline: Deadline) throws -> [Int32: [UInt8]]? {
        let queue = kqueue()
        guard queue >= 0 else { throw unheard("could not be watched") }
        defer { close(queue) }
        func watch(_ ident: UInt, _ filter: Int32, _ flags: Int32, _ fflags: UInt32 = 0) -> Int32 {
            var change = kevent(ident: ident, filter: Int16(filter), flags: UInt16(flags | EV_RECEIPT), fflags: fflags, data: 0, udata: nil)
            var receipt = kevent()
            return kevent(queue, &change, 1, &receipt, 1, nil) == 1 ? Int32(receipt.data) : errno
        }
        for stream in streams {
            let refused = watch(UInt(stream), EVFILT_READ, EV_ADD)
            guard refused == 0 else { throw unheard("could not be watched", refused) }
        }
        // A child that has ended already is not there to be watched, and that is its exit
        // said another way: its pid is this call's until it is collected, so no such
        // process is this child, ended.
        let gone = watch(UInt(pid), EVFILT_PROC, EV_ADD, UInt32(NOTE_EXIT))
        guard gone == 0 || gone == ESRCH else { throw unheard("could not be watched", gone) }
        var exited = gone == ESRCH
        var open = Set(streams)
        var carried: [Int32: [UInt8]] = [:]
        var events = Array(repeating: Darwin.kevent(), count: streams.count + 1)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !(exited && open.isEmpty) {
            let left = SuspendingClock.now.duration(to: deadline.at)
            guard left > .zero else { return nil }
            var patience = timespec(tv_sec: Int(left.components.seconds), tv_nsec: Int(left.components.attoseconds / 1_000_000_000))
            let ready = kevent(queue, nil, 0, &events, Int32(events.count), &patience)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw unheard("could not be watched") }
            for event in events.prefix(Int(ready)) {
                guard event.filter == Int16(EVFILT_READ) else { exited = true; continue }
                let stream = Int32(event.ident)
                let count = read(stream, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw unheard("could not be heard") }
                carried[stream, default: []] += buffer.prefix(count)
                // An empty read is the end of the stream, and it is the only thing that
                // says so. The watch goes with it: an ended stream is ready at every look.
                if count == 0 {
                    open.remove(stream)
                    let kept = watch(UInt(stream), EVFILT_READ, EV_DELETE)
                    guard kept == 0 else { throw unheard("could not be watched", kept) }
                }
            }
        }
        return carried
    }
}

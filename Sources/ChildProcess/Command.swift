import Foundation
import Synchronization
import Timeline

/// One command run against the machine, and everything it said.
///
/// Small on purpose: a reading needs a status and two streams, and a general process
/// wrapper would be a second thing to maintain for the sake of arguments nobody passes.
/// [LAW:single-enforcer] Every command either half runs to read this Mac is run here: the
/// driver probe's, `vhid doctor`'s launchd reading, the grant reading and the screen
/// capture, so each is heard to its end, bounded, and stopped the one way.
public struct Command: Sendable {
    public let tool: URL
    public let arguments: [String]
    /// The child's environment: this process's when nil.
    public let environment: [String: String]?

    public init(_ tool: String, _ arguments: String...) {
        self.init(tool, arguments)
    }

    public init(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) {
        self.tool = URL(fileURLWithPath: tool)
        self.arguments = arguments
        self.environment = environment
    }

    public struct Output: Sendable {
        /// What it exited with, or the signal that ended it.
        public let ending: Ending
        public let stdout: String
        public let stderr: String

        public init(ending: Ending, stdout: String, stderr: String) {
            self.ending = ending
            self.stdout = stdout
            self.stderr = stderr
        }

        public init(status: Int32, stdout: String, stderr: String) {
            self.init(ending: .exited(status), stdout: stdout, stderr: stderr)
        }

        /// The exit status, or the signal's number for a child a signal ended.
        public var status: Int32 { switch ending { case .exited(let code), .signalled(let code): code } }
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

    /// What ends a reading before its deadline, pulled from whichever thread hears the
    /// cancel while the reading blocks another.
    ///
    /// A stop pulled stays pulled: a command the reading runs afterwards is not started, so
    /// a reading of several commands ends at the one running and runs no more.
    public final class Stop: Sendable {
        /// Whether it has been pulled, the kqueues of the commands waiting on it now and
        /// what each runs, and the commands it has ended. Changed under one lock, so a
        /// command that starts as the stop is pulled is woken either way: by the pull, or
        /// as it starts, by finding it pulled.
        private let state = Mutex<(pulled: Bool, waiting: [Int32: String], ended: [String])>((false, [:], []))

        public init() {}

        /// A stop nobody holds, for a reading that runs to its end: a fresh one each time,
        /// so no pull of one reaches another.
        public static var never: Stop { Stop() }

        /// Ends the reading.
        public func pull() {
            state.withLock { state in
                state.pulled = true
                state.ended += state.waiting.values.sorted()
                state.waiting.keys.forEach(Self.trigger)
            }
        }

        /// The commands this stop ended, each as it was run: the one running when it was
        /// pulled. Empty for a stop pulled while no command ran, which is what says the
        /// reading was waiting on something else.
        public var ended: [String] {
            state.withLock { $0.ended }
        }

        /// Throws the cancel where the stop has been pulled, so a stopped reading starts no
        /// command: one like `open` acts as it starts, before any kill could reach it. A
        /// pull that lands after this is heard by `wake`.
        fileprivate func admit() throws(CancellationError) {
            if state.withLock({ $0.pulled }) { throw CancellationError() }
        }

        /// Wakes `queue`, which is running `command`, when the stop is pulled, which can be
        /// now. `queue` is watched for the wake already, and is not closed before `forget`
        /// takes it back.
        fileprivate func wake(_ queue: Int32, running command: String) {
            state.withLock { state in
                state.waiting[queue] = command
                if state.pulled {
                    state.ended.append(command)
                    Self.trigger(queue)
                }
            }
        }

        fileprivate func forget(_ queue: Int32) {
            _ = state.withLock { $0.waiting.removeValue(forKey: queue) }
        }

        /// The event `hear` watches for, set off. Nothing is lost when this fails: the
        /// queue is a reading's own and one it cannot be woken on is one that is closing.
        private static func trigger(_ queue: Int32) {
            var trigger = kevent(ident: 0, filter: Int16(EVFILT_USER), flags: 0, fflags: UInt32(NOTE_TRIGGER), data: 0, udata: nil)
            _ = kevent(queue, &trigger, 1, nil, 0, nil)
        }
    }

    /// A command that had not ended at its deadline: the child still running, or a stream
    /// of it still open in something the child started.
    ///
    /// `had` is how long this command had, to the millisecond, beside the limit of the
    /// reading it was run for: the command a reading's limit ends on is the one running
    /// then, and may have had a moment of it where one before it had the rest.
    public struct Overran: Error, CustomStringConvertible, Equatable {
        public let command: String
        public let had: Duration
        public let limit: Duration

        public var description: String { "`\(command)` had not ended \(had) after it was started, at the limit of \(limit), and was given up on" }
    }

    /// A command not started because its reading's deadline had passed before its turn
    /// came: the commands before it, or the wait for a thread to run it on, took the whole
    /// limit. Nothing was spawned.
    public struct Unstarted: Error, CustomStringConvertible, Equatable {
        public let command: String
        public let limit: Duration

        public var description: String { "`\(command)` was not started: its reading's limit of \(limit) had passed" }
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
    /// `Overran`, or to `stop`, where it is thrown as a `CancellationError`.
    /// [LAW:types-are-the-program] The deadline is not optional, so nothing this program
    /// runs can hold its caller for good. Nor is the stop: a caller says which, and one
    /// nobody pulls is `.never`, the reading that runs to its end.
    ///
    /// Admitted first, and not started at all when it is not: a pulled stop throws the
    /// cancel, and a deadline already passed throws `Unstarted`. [LAW:single-enforcer] One
    /// door for both, so a reading of several commands starts none past the one its limit
    /// or its stop ended.
    ///
    /// The child is this call's from `spawn` to `collect`: nothing of it is left once this
    /// returns or throws, not a descriptor and not a pid to collect.
    public func run(by deadline: Deadline, or stop: Stop) throws -> Output {
        try stop.admit()
        guard !deadline.passed else { throw Unstarted(command: said, limit: deadline.limit) }
        // [LAW:one-source-of-truth] What this command has is read off its deadline, so the
        // span it overran and the limit that ended it are kept on one clock.
        let had = deadline.left
        // Nothing to read: a reading takes no input, and under an MCP server this process's
        // own stdin is the client's JSON-RPC stream, which a child must not take from.
        let nothing = open("/dev/null", O_RDONLY)
        guard nothing >= 0 else { throw unheard("could not be given an empty stdin") }
        let out: (read: Int32, write: Int32)
        do { out = try pipe() } catch {
            close(nothing)
            throw error
        }
        let err: (read: Int32, write: Int32)
        do { err = try pipe() } catch {
            close(nothing); close(out.read); close(out.write)
            throw error
        }
        defer { close(out.read); close(err.read) }
        let pid: pid_t
        do {
            // The writing ends are the child's once it has them: one left open here is a
            // stream that never ends.
            defer { close(out.write); close(err.write); close(nothing) }
            pid = try spawn(tool.path, arguments, stdio: [0: nothing, 1: out.write, 2: err.write], environment: environment)
        }
        let heard = Result { try hear(pid, [out.read, err.read], by: deadline, or: stop) }
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
        let streams: [Int32: [UInt8]]
        switch try heard.get() {
        case .ended(let carried):
            streams = carried
        case .overran:
            throw Overran(command: said, had: .milliseconds(had.wholeMilliseconds), limit: deadline.limit)
        case .stopped:
            throw CancellationError()
        }
        return Output(
            ending: ending,
            stdout: String(decoding: streams[out.read, default: []], as: UTF8.self),
            stderr: String(decoding: streams[err.read, default: []], as: UTF8.self)
        )
    }

    private func pipe() throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard Darwin.pipe(&ends) == 0 else { throw unheard("could not be given a pipe") }
        return (ends[0], ends[1])
    }

    /// How a hearing ended: with everything each stream carried, once the child had exited
    /// and every stream had ended, or at the deadline or its stop, whichever came first.
    private enum Heard {
        case ended([Int32: [UInt8]])
        case overran
        case stopped
    }

    /// Hears the child out, by `deadline` or `stop`.
    ///
    /// The exit and the streams are waited for at once, on one queue. A child whose pipe
    /// fills blocks in `write(2)` until someone reads it, so a stream that waits its turn
    /// is a stream whose turn can never come: the child cannot reach the exit that would
    /// end the read being waited on. [LAW:no-ambient-temporal-coupling] Watching all of it
    /// from the start leaves no order to get wrong.
    private func hear(_ pid: pid_t, _ streams: [Int32], by deadline: Deadline, or stop: Stop) throws -> Heard {
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
        let stoppable = watch(0, EVFILT_USER, EV_ADD | EV_CLEAR)
        guard stoppable == 0 else { throw unheard("could not be watched", stoppable) }
        stop.wake(queue, running: said)
        defer { stop.forget(queue) }
        var exited = gone == ESRCH
        var open = Set(streams)
        var carried: [Int32: [UInt8]] = [:]
        var events = Array(repeating: Darwin.kevent(), count: streams.count + 2)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !(exited && open.isEmpty) {
            let left = deadline.left
            guard left > .zero else { return .overran }
            var patience = left.timespec
            let ready = kevent(queue, nil, 0, &events, Int32(events.count), &patience)
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { throw unheard("could not be watched") }
            for event in events.prefix(Int(ready)) {
                if event.filter == Int16(EVFILT_USER) { return .stopped }
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
        return .ended(carried)
    }
}

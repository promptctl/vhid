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
    public struct Deadline: Sendable {
        public let limit: Duration
        fileprivate let at: DispatchTime

        /// Over `limit` from now.
        public static func within(_ limit: Duration) -> Deadline {
            let nanoseconds = limit.components.seconds * 1_000_000_000 + limit.components.attoseconds / 1_000_000_000
            return Deadline(limit: limit, at: .now() + .nanoseconds(Int(nanoseconds)))
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

    /// Runs the command to its end, or to `deadline`, where it is given up on and thrown as
    /// `Overran`. [LAW:types-are-the-program] The deadline is not optional, so nothing this
    /// program runs can hold its caller for good.
    ///
    /// Nothing of it is open once this returns: the pipes' handles are autoreleased, and
    /// close only when a pool drains, so the pool is here and not the caller's to have. A
    /// daemon's thread that never returns drains none.
    public func run(by deadline: Deadline) throws -> Output {
        try autoreleasepool {
            let process = Process()
            process.executableURL = tool
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            let outDrain = Drain(out.fileHandleForReading)
            let errDrain = Drain(err.fileHandleForReading)
            let started = ContinuousClock.now
            try process.run()
            // One deadline for the exit and both streams, as for every command of the
            // reading.
            guard exited.wait(timeout: deadline.at) == .success,
                let stdout = outDrain.text(by: deadline.at),
                let stderr = errDrain.text(by: deadline.at)
            else {
                outDrain.stop()
                errDrain.stop()
                // The child is stopped, and what it started is not reached: a stream held
                // open past the child's exit is let go of here and goes on being held there.
                // SIGKILL, because a tool that is stuck may not be answering SIGTERM. Only
                // while it runs: a child that has exited has a pid that is no longer its.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                let ran = ContinuousClock.now - started
                throw Overran(
                    command: ([tool.lastPathComponent] + arguments).joined(separator: " "),
                    ran: .milliseconds(ran.components.seconds * 1000 + ran.components.attoseconds / 1_000_000_000_000_000),
                    limit: deadline.limit
                )
            }
            return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        }
    }
}

/// One stream, read from before the child starts until the stream ends.
///
/// A command holds two of these at once, and that is the whole reason the type exists: a
/// child whose pipe fills blocks in `write(2)` until someone reads it, so a stream that
/// waits its turn is a stream whose turn can never come - the child cannot reach the exit
/// that would end the read we are waiting on. [LAW:no-ambient-temporal-coupling] Both
/// draining from the start leaves no order to get wrong, rather than an order to get right.
private final class Drain: @unchecked Sendable {
    // [LAW:no-shared-mutable-globals] `bytes` is written on the handler's queue and read on
    // the caller's; the lock is the named owner of that crossing.
    private let lock = NSLock()
    private var bytes = Data()
    private let ended = DispatchSemaphore(value: 0)
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [self] handle in
            let chunk = handle.availableData
            lock.withLock { bytes.append(chunk) }
            // An empty read is EOF, and it is the only thing that says the stream ended.
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                ended.signal()
            }
        }
    }

    /// Everything the stream carried, or nil when it had not ended by `deadline`.
    func text(by deadline: DispatchTime) -> String? {
        guard ended.wait(timeout: deadline) == .success else { return nil }
        return lock.withLock { String(decoding: bytes, as: UTF8.self) }
    }

    /// Gives up on a stream that has not ended: with the handler gone the handle is free
    /// to close, where one still being read is held open with its descriptor.
    func stop() {
        handle.readabilityHandler = nil
    }
}

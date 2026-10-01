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

    /// How long a command that reads this Mac is given. The tools read in hundredths of a
    /// second, and vhidd reads the driver before it answers a client it refuses, who waits
    /// five seconds for that answer (`HelperConnection`): a tool that never ends is given
    /// up on while the client is still listening.
    public static let readingLimit: Duration = .seconds(2)

    /// A command that had not ended at its limit: the child still running, or a stream of
    /// it still open in something the child started.
    public struct Overran: Error, CustomStringConvertible, Equatable {
        public let command: String
        public let limit: Duration

        public var description: String { "`\(command)` had not ended after \(limit) and was stopped" }
    }

    /// Runs the command to its end, or to `limit`, where it is stopped and thrown as
    /// `Overran`. [LAW:types-are-the-program] The limit is not optional, so nothing this
    /// program runs can hold its caller for good.
    ///
    /// Nothing of it is open once this returns: the pipes' handles are autoreleased, and
    /// close only when a pool drains, so the pool is here and not the caller's to have. A
    /// daemon's thread that never returns drains none.
    public func run(within limit: Duration) throws -> Output {
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
            try process.run()
            // [LAW:no-ambient-temporal-coupling] One deadline for the exit and both
            // streams, so the limit is the command's and not each wait's.
            let nanoseconds = limit.components.seconds * 1_000_000_000 + limit.components.attoseconds / 1_000_000_000
            let deadline = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
            guard exited.wait(timeout: deadline) == .success,
                let stdout = outDrain.text(by: deadline),
                let stderr = errDrain.text(by: deadline)
            else {
                outDrain.stop()
                errDrain.stop()
                // SIGKILL, because a tool that is stuck may not be answering SIGTERM. Only
                // while it runs: a child that has exited has a pid that is no longer its.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                throw Overran(command: ([tool.lastPathComponent] + arguments).joined(separator: " "), limit: limit)
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

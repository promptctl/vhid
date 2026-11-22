import Foundation

/// A FIFO a child writes its pid into when it has started, which the test reads to know
/// it is running and which process it is.
///
/// [LAW:no-ambient-temporal-coupling] The child's start is an event the test reads, never a
/// file it polls for. Both ends are opened as the handshake is made, the reading one on a
/// thread of its own, so a child's write never waits on the test, the pid is there the
/// moment the child has written its line, and `remove` ends the read by closing the one
/// end it holds, whenever it is called.
public final class Handshake: Sendable {
    public let path: String
    /// Held so the read sees no end of file before the child's line, and closed by `remove`,
    /// which is how a read nobody wrote to ends. One child's line is read: a handshake is
    /// made for each child.
    private let writer: Int32
    private let heard = Latch<Result<String, Failure>?>(nil)

    /// A call that failed, with its errno.
    public struct Failure: Error, CustomStringConvertible {
        public let call: String
        public let code: Int32

        public var description: String { "\(call) \(String(cString: strerror(code))) (\(code))" }
    }

    public init() throws(Failure) {
        let path = FileManager.default.temporaryDirectory.appending(path: "handshake-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw Failure(call: "mkfifo \(path)", code: errno) }
        // The reading end opens without a writer only when it does not wait for one, and the
        // writing end opens without waiting only once there is a reader: so the reader
        // first, then the writer, then the read made to wait for the child's line.
        // A handshake not made leaves nothing behind: every end opened is closed, and the
        // FIFO removed.
        let reader = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard reader >= 0 else { defer { unlink(path) }; throw Failure(call: "open \(path) to read", code: errno) }
        let writer = open(path, O_WRONLY | O_CLOEXEC)
        guard writer >= 0 else { defer { close(reader); unlink(path) }; throw Failure(call: "open \(path) to write", code: errno) }
        guard fcntl(reader, F_SETFL, 0) == 0 else { defer { close(reader); close(writer); unlink(path) }; throw Failure(call: "fcntl \(path)", code: errno) }
        self.path = path
        self.writer = writer
        Thread.detachNewThread { [heard] in
            heard.update { $0 = Self.readLine(reader, path) }
        }
    }

    /// The shell words a child runs to say it has started: its pid, written into the FIFO.
    public var said: String { "echo $$ > '\(path)'" }

    /// The pid the child wrote, once it has written it. Throws `Hung` when no child writes
    /// by the guard.
    public func pid(_ what: String) throws -> pid_t {
        let said = try heard.wait(for: what) { $0 }.get()
        guard let pid = pid_t(said) else { throw Failure(call: "read a pid from \"\(said)\" in \(path)", code: EINVAL) }
        return pid
    }

    /// Lets the read go, written to or not, and removes the FIFO: with its last writer
    /// closed, a read nobody wrote to ends, so no thread is left blocked on it.
    public func remove() {
        close(writer)
        unlink(path)
    }

    /// The first line written, or what was written before the end of file, and the reading
    /// end closed either way.
    private static func readLine(_ fd: Int32, _ path: String) -> Result<String, Failure> {
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64)
        while !bytes.contains(UInt8(ascii: "\n")) {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(Failure(call: "read \(path)", code: errno))
            }
            if count == 0 { break }
            bytes += chunk[..<count]
        }
        return .success(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

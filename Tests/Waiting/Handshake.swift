import Foundation

/// A FIFO a child writes its pid into when it has started, which the test reads to know
/// it is running and which process it is.
///
/// [LAW:no-ambient-temporal-coupling] The child's start is an event the test reads, never a
/// file it polls for. The FIFO is opened to read as the handshake is made, on a thread of
/// its own, so a child's write never waits on the test and the pid is there the moment the
/// child has written it.
public final class Handshake: Sendable {
    public let path: String
    private let heard = Latch<Result<String, Failure>?>(nil)

    /// A call that failed, with its errno.
    public struct Failure: Error, CustomStringConvertible {
        public let call: String
        public let code: Int32

        public var description: String { "\(call) \(String(cString: strerror(code))) (\(code))" }
    }

    public init() throws(Failure) {
        path = FileManager.default.temporaryDirectory.appending(path: "handshake-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw Failure(call: "mkfifo \(path)", code: errno) }
        Thread.detachNewThread { [path, heard] in
            heard.update { $0 = Self.readToEnd(path) }
        }
    }

    /// The shell words a child runs to say it has started: its pid, written into the FIFO.
    public var said: String { "echo $$ > '\(path)'" }

    /// The pid the child wrote, once it has written it. Throws `Hung` when no child writes
    /// by the guard.
    public func pid(_ what: String) throws -> pid_t {
        let said = try heard.wait(for: what) { $0 != nil }!.get()
        guard let pid = pid_t(said) else { throw Failure(call: "read a pid from \"\(said)\" in \(path)", code: EINVAL) }
        return pid
    }

    /// Lets the read go, written to or not, and removes the FIFO: a reader nobody wrote to
    /// is given an empty write, so no thread is left blocked on it.
    public func remove() {
        close(open(path, O_WRONLY | O_NONBLOCK))
        unlink(path)
    }

    private static func readToEnd(_ path: String) -> Result<String, Failure> {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return .failure(Failure(call: "open \(path)", code: errno)) }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64)
        while true {
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

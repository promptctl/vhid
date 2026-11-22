import Foundation

/// A FIFO a child writes its pid into when it has started, which the test reads to know
/// it is running and which process it is.
///
/// [LAW:no-ambient-temporal-coupling] The child's start is an event the test reads, never a
/// file it polls for: opening a FIFO to read blocks until a writer opens it, so the read
/// ends the moment the child speaks.
public struct Handshake: Sendable {
    public let path: String

    /// A call that failed, with its errno.
    public struct Failure: Error, CustomStringConvertible {
        public let call: String
        public let code: Int32

        public var description: String { "\(call) \(String(cString: strerror(code))) (\(code))" }
    }

    public init() throws(Failure) {
        path = FileManager.default.temporaryDirectory.appending(path: "handshake-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw Failure(call: "mkfifo \(path)", code: errno) }
    }

    /// The shell words a child runs to say it has started: its pid, written into the FIFO.
    public var said: String { "echo $$ > '\(path)'" }

    /// The pid the child wrote, read once it has written it. Throws `Hung` when no child
    /// writes by the guard; the read is then let go by opening the FIFO to write from here,
    /// so no thread is left blocked on it.
    public func pid(_ what: String) throws -> pid_t {
        let heard = Latch<Result<String, Failure>?>(nil)
        Thread.detachNewThread { [path] in
            heard.update { $0 = Self.readToEnd(path) }
        }
        let line: Result<String, Failure>
        do {
            line = try heard.wait(for: what) { $0 != nil }!
        } catch {
            close(open(path, O_WRONLY | O_NONBLOCK))
            throw error
        }
        let said = try line.get()
        guard let pid = pid_t(said) else { throw Failure(call: "read a pid from \"\(said)\" in \(path)", code: EINVAL) }
        return pid
    }

    /// Removes the FIFO.
    public func remove() {
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

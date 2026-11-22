import Foundation

/// A named pipe a child writes one line to once it is running, which is how a test waits
/// for a child to start without polling for a file. Opening it to read blocks until the
/// child opens it to write. Removed when the last holder lets go.
public final class FIFO: Sendable {
    public let path: String

    public init() throws {
        path = FileManager.default.temporaryDirectory.appending(path: "vhid-fifo-\(UUID().uuidString)").path
        guard mkfifo(path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    deinit { unlink(path) }

    /// The first line written, once a writer has written it and closed its end.
    public func readLine() -> String {
        let data = FileHandle(forReadingAtPath: path)?.readDataToEndOfFile() ?? Data()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `readLine` on a queue of its own, for a test whose tasks share one thread: a read
    /// blocked there would hold up the child's parent it waits on.
    public func line() async -> String {
        await withCheckedContinuation { read in
            DispatchQueue(label: "OwnThread.FIFO").async { read.resume(returning: self.readLine()) }
        }
    }
}

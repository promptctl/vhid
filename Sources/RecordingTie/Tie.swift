import Foundation

/// What the `vhid record` command and its tap app say to each other over the socket
/// between them. `docs/design/replay.md`, "The grant recording needs", is the design: the
/// app is launched through LaunchServices, so it is not the command's child, and this
/// socket and a watch on the command's pid are all that ties the two together.
///
/// One JSON object per line, both ways. [LAW:parse-dont-validate] A line either decodes
/// to one of these or is refused as not a message, so neither end reads raw text.
public enum ToApp: String, Codable, Sendable {
    /// SIGINT: the person pressed Control-C, whose keys are in the recording and come out.
    case stop
    /// Any other ending - SIGTERM - which drops nothing.
    case end
}

public enum FromApp: Codable, Equatable, Sendable {
    /// The app will not record, and why, in words for a person.
    case refused(String)
    /// The tap is running.
    case recording
    /// Something the person should hear about the recording, on stderr.
    case note(String)
    /// The recording, whole, as `vhid play` reads it, with how it ended and what it left out:
    /// the last message, and one, so no script arrives without its summary.
    /// [LAW:types-are-the-program]
    case recorded(Summary, script: String)
}

/// How a recording ended and what it left out, as the command keeps it on its record.
/// [LAW:types-are-the-program] The ending is a case, not words, so a record says which
/// ending it was the way a test can ask.
public struct Summary: Codable, Equatable, Sendable {
    public let ending: Ending
    /// Key presses with no HID usage, fn among them, left out.
    public let unmappedKeys: Int
    /// Motion of vhid's that ended on a display's edge, after which the person's points may be off.
    public let vhidAtEdge: Int
    /// The person's moves that, with vhid's motion taken out, were on no display, left out.
    public let unplacedMoves: Int

    public init(ending: Ending, unmappedKeys: Int, vhidAtEdge: Int, unplacedMoves: Int) {
        self.ending = ending
        self.unmappedKeys = unmappedKeys
        self.vhidAtEdge = vhidAtEdge
        self.unplacedMoves = unplacedMoves
    }

    /// What the person should hear of what the recording left out or may have wrong, one note
    /// a count that is not zero: worded from these counts, so the notes and the record cannot
    /// disagree. [LAW:one-source-of-truth]
    public var notes: [String] {
        [(unmappedKeys, "\(unmappedKeys) key presses with no HID usage, fn among them, are not in the recording"),
         (vhidAtEdge, "vhid's motion reached a screen edge \(vhidAtEdge) times while recording, so the pointer points after it may be off"),
         (unplacedMoves, "\(unplacedMoves) of the person's moves were on no display once vhid's motion was taken out, and are not in the recording")]
            .filter { $0.0 > 0 }.map(\.1)
    }

    public enum Ending: String, Codable, Sendable {
        /// Control-C, whose keys came out.
        case stopped
        /// Any other stop of the command's, which drops nothing.
        case ended
        /// macOS turned the tap off, so events were missed from there.
        case tapOff = "tap_off"
        /// An hour, as long as a script plays.
        case hour
        /// vhid's devices came back and could not be told apart again.
        case devicesUntold = "devices_untold"
        /// The tap gave an event at no place on the screen.
        case tapAtNoPlace = "tap_at_no_place"
        /// The display layout could not be read to tell an edge or place a point.
        case layoutUnreadable = "layout_unreadable"
    }
}

/// One end of the socket, as lines of messages.
///
/// A class because it owns a descriptor, closed exactly once when the last holder lets go.
public final class TieEnd: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private let writing = NSLock()

    init(descriptor: Int32) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// The app's end: connects to the command's socket at `path`.
    public static func connect(to path: String) throws -> TieEnd {
        let descriptor = try socketDescriptor()
        var address = try Self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            let error = errno
            close(descriptor)
            throw TieFailure("could not connect to \(path): \(String(cString: strerror(error)))")
        }
        return TieEnd(descriptor: descriptor)
    }

    public func send(_ message: some Encodable) throws {
        let line = try JSONEncoder().encode(message) + Data("\n".utf8)
        writing.lock(); defer { writing.unlock() }
        try handle.write(contentsOf: line)
    }

    /// The next message, waiting for it; nil once the other end has closed.
    public func receive<Message: Decodable>(_: Message.Type) throws -> Message? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                do {
                    return try JSONDecoder().decode(Message.self, from: line)
                } catch {
                    throw TieFailure("the other end sent a line that is not a \(Message.self): \(String(decoding: line, as: UTF8.self))")
                }
            }
            // read(2) and not FileHandle's read(upToCount:), which waits for the whole count
            // on a socket rather than answering with what has arrived.
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(handle.fileDescriptor, &chunk, chunk.count)
            guard count >= 0 else { throw TieFailure("could not read the socket: \(String(cString: strerror(errno)))") }
            guard count > 0 else {
                guard buffer.isEmpty else { throw TieFailure("the other end closed partway through a line") }
                return nil
            }
            buffer.append(contentsOf: chunk[..<count])
        }
    }

    static func socketDescriptor() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TieFailure("could not make a socket: \(String(cString: strerror(errno)))") }
        return descriptor
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw TieFailure("the socket path \(path) is longer than a Unix socket's path can be")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}

/// The command's end before the app has connected: a socket in a directory only this
/// user can read, removed with it.
public final class TieListener: @unchecked Sendable {
    public let path: String
    private let directory: String
    private let descriptor: Int32

    public init() throws {
        // mkdtemp makes the directory 0700, so no other user can reach the socket in it.
        var template = Array((FileManager.default.temporaryDirectory.path + "/vhid-record.XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else { throw TieFailure("could not make a directory for the socket: \(String(cString: strerror(errno)))") }
        directory = String(cString: made)
        path = directory + "/tie"
        do {
            descriptor = try TieEnd.socketDescriptor()
        } catch {
            rmdir(directory)
            throw error
        }
        var address = try TieEnd.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Every property is set, so deinit closes the socket and removes the directory.
        guard bound == 0, listen(descriptor, 1) == 0 else {
            let error = errno
            throw TieFailure("could not listen on \(path): \(String(cString: strerror(error)))")
        }
    }

    deinit {
        close(descriptor)
        unlink(path)
        rmdir(directory)
    }

    /// The app's end, once it connects, or a failure once `limit` has passed without it.
    public func accept(within limit: Duration) throws -> TieEnd {
        var waiting = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(limit.components.seconds * 1000 + limit.components.attoseconds / 1_000_000_000_000_000)
        guard poll(&waiting, 1, milliseconds) == 1 else {
            throw TieFailure("the tap app did not connect within \(limit)")
        }
        let accepted = Darwin.accept(descriptor, nil, nil)
        guard accepted >= 0 else { throw TieFailure("could not accept the tap app: \(String(cString: strerror(errno)))") }
        return TieEnd(descriptor: accepted)
    }
}

/// The app's watch on the command's pid: `ended` runs once the command has gone, however
/// it went - SIGKILL included, which closes nothing the app could read.
public final class CommandWatch: @unchecked Sendable {
    private let source: any DispatchSourceProcess

    public init(pid: pid_t, queue: DispatchQueue, ended: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler(handler: ended)
        source.resume()
        // A source on a pid that has already ended never fires, so it is asked once after
        // the source is registered: a pid that ended before this is caught here, and one
        // that ends after it by the source.
        if Self.ended(pid) { queue.async(execute: ended) }
    }

    /// Whether `pid` has ended: gone, or a zombie its parent has not reaped yet, which
    /// `kill(pid, 0)` still answers for and a process source never fires on.
    static func ended(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return true }
        // A zombie has no task left, which proc_pidinfo says whatever p_stat reads.
        var task = proc_taskinfo()
        let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0
        return size == 0 || info.kp_proc.p_stat == SZOMB || !hasTask
    }

    deinit { source.cancel() }
}

public struct TieFailure: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

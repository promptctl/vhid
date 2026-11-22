import Foundation
import Time

/// One connection to Karabiner-VirtualHIDDevice-Daemon over its Unix domain stream
/// socket. Every failure names what the daemon did or did not say. [LAW:no-silent-failure]
///
/// Why a daemon and not the driver: opening the driver extension's user client requires
/// `com.apple.developer.driverkit.userclient-access` naming
/// `org.pqrs.Karabiner-DriverKit-VirtualHIDDevice`, which Apple grants per application
/// identifier and which only pqrs's own daemon holds. Root does not help; measured, in
/// low-talker's 3ti.2 spike. So the daemon is the way in.
///
/// **The caller must be root.** The socket's directory is mode 0700 owned by root, so a
/// process that is not root cannot see the socket at all. That is stated here once and
/// never re-checked inland: a privilege this type cannot acquire is not a condition for it
/// to keep testing. [LAW:no-defensive-null-guards]
///
/// **The socket is read by one thread for the life of the connection.** The daemon talks
/// when nobody has asked it anything - a heartbeat every three seconds, a health check
/// now and then, a status push when the driver changes state - and it hangs up on a
/// client that has said nothing for fifteen seconds, measured on this Mac. A connection
/// read only while a request was in flight went quiet between calls and was found dead
/// by the next write. So the reading is not part of asking; it is a lifecycle with its own
/// owner, and asking is queuing a request for the one thread that writes and waiting to be
/// told the answer arrived. [LAW:no-ambient-temporal-coupling]
///
/// **Every wait is on the process's timeline**: the heartbeat, the patience, a stalled
/// write and every request's wait for its answer, so a test that moves its clock wakes each
/// of them and none waits out a real span.
///
/// **One connection carries both devices.** The daemon keeps a keyboard and a pointing
/// device per client connection and destroys both when the client hangs up, so a client
/// that owns a keyboard and a mouse holds one of these and hands it to each.
public final class DaemonConnection: Sendable {
    static let socketPath = "/Library/Application Support/org.pqrs/tmp/rootonly/karabiner_virtual_hid_device_service.sock"
    /// The version this side speaks, from `virtual_hid_device_service/client.hpp`. Two
    /// bytes, and native-endian unlike everything around it - the framing is big-endian
    /// and the report inside is little-endian, and none of the three announces itself.
    static let clientProtocolVersion: UInt16 = 7
    /// The daemon's own cadence, measured: it sends a heartbeat every three seconds and
    /// drops a client silent for fifteen. Matching it keeps this side well inside the
    /// patience of a daemon whose patience is not written down anywhere this side can read.
    static let heartbeatInterval: Duration = .seconds(3)
    /// How long the daemon may say nothing before it is taken for gone: its own fifteen
    /// seconds, mirrored. A peer that stalled without closing - suspended, wedged mid-frame
    /// - sends no heartbeat and no end of stream, and a reader that only waits for one of
    /// those would wait forever, sending its own heartbeats into the dark.
    static let patience: Duration = .seconds(15)

    /// The request table, by index, from `virtual_hid_device_service/request.hpp`.
    enum Request: UInt8 {
        case keyboardInitialize = 0
        case keyboardTerminate = 1
        case keyboardReset = 2
        case pointingInitialize = 3
        case pointingTerminate = 4
        case pointingReset = 5
        case postKeyboardInputReport = 6
        case postPointingInputReport = 11
    }

    /// The status table, by index, from `virtual_hid_device_service/response.hpp`.
    public enum Status: UInt8, Sendable {
        case none = 0
        case driverActivated = 1
        case driverConnected = 2
        case driverVersionMismatched = 3
        case keyboardReady = 4
        case pointingReady = 5

        /// The words `DaemonError` reports this status in.
        public var name: String {
            switch self {
            case .none: "none"
            case .driverActivated: "driver activated"
            case .driverConnected: "driver connected"
            case .driverVersionMismatched: "driver version mismatched"
            case .keyboardReady: "keyboard ready"
            case .pointingReady: "pointing ready"
            }
        }
    }

    private let link: Link

    /// Connects to the daemon at the path above.
    ///
    /// `whenLost` is told, once, from the reading thread, when the connection ends for
    /// any reason but this side hanging up: the daemon closed it, the socket failed, the
    /// wire carried something this side cannot read, or the daemon took back a status it
    /// had said held. Every later request throws the
    /// same failure, so a caller that only ever asks can leave it be; a process that
    /// holds the connection open across long silences is the one that needs to hear.
    public convenience init(timeline: Timeline, whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }) throws {
        guard FileManager.default.fileExists(atPath: Self.socketPath) else { throw DaemonError.noSocket(path: Self.socketPath) }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw DaemonError.socket("socket", errno) }
        // Connected before anything reads it: a reader on an unconnected socket reports a
        // failure that is really this side's own ordering. The descriptor has no owner
        // yet, so a refused connection closes it here and nowhere else.
        do { try Self.connect(descriptor) } catch { close(descriptor); throw error }
        try self.init(fileDescriptor: descriptor, timeline: timeline, whenLost: whenLost)
    }

    /// A connection over a descriptor someone else opened. This is the seam that makes
    /// the wire protocol testable: a `socketpair` puts a fake daemon on the other end, so
    /// the framing, the deadlines, the heartbeats and the request/response matching are
    /// exercised over a real socket rather than mocked away. [LAW:decomposition] The
    /// protocol and the pipe it runs over are two things, and only one of them needs root.
    ///
    /// The heartbeat interval and the patience are parameters so a test can watch a
    /// heartbeat go out, or a silence be noticed, at an interval of its own. `readingEnded`
    /// is told when the reading thread has ended, so a test can say nothing was reported by
    /// then, rather than by a sleep it hopes was long enough.
    init(fileDescriptor: Int32, timeline: Timeline, heartbeatEvery interval: Duration = DaemonConnection.heartbeatInterval, patience: Duration = DaemonConnection.patience, whenLost: @escaping @Sendable (DaemonError) -> Void = { _ in }, readingEnded: @escaping @Sendable () -> Void = {}) throws {
        // The link owns the descriptor from this line, so an initializer that throws past
        // it still closes exactly once, when the link goes.
        link = Link(socket: fileDescriptor, timeline: timeline, heartbeatEvery: interval, patience: patience, whenLost: whenLost, readingEnded: readingEnded)
        try refuseSIGPIPE(fileDescriptor)
        try neverBlock(fileDescriptor)
        link.start()
    }

    /// Hangs up. The reading thread sees the end of the stream and the writing thread is
    /// woken to find it; both finish and let go of the link, which is when the descriptor
    /// closes. [LAW:single-enforcer]
    deinit {
        link.hangUp()
    }

    private static func connect(_ socket: Int32) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(Self.socketPath.utf8CString)
        precondition(path.count <= MemoryLayout.size(ofValue: address.sun_path), "the socket path outgrew sun_path")
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw DaemonError.socket("connect", errno) }
    }

    // MARK: - Requests

    /// The daemon's latest word on each status it has ever sent.
    var status: [Status: Bool] { link.currentStatus }

    /// Sends a request and waits for the daemon's answer to it by `deadline`, answering when
    /// the answer was read. Every request is answered, including a posted report, so waiting
    /// on the answer is real flow control rather than a sleep guessed at.
    /// [LAW:no-ambient-temporal-coupling] Unanswered, it throws how far it got and why, which
    /// is what says whether the driver may have it.
    @discardableResult
    func request(_ request: Request, _ payload: [UInt8] = [], by deadline: Deadline) throws(Unanswered) -> Instant {
        let version = Self.clientProtocolVersion
        return try link.ask([UInt8(version & 0xff), UInt8(version >> 8), request.rawValue] + payload, by: deadline)
    }

    /// Waits until the daemon has said `status` holds, however long ago it said so. The
    /// wait is on the daemon's word, never a sleep - but note what the word costs: the
    /// daemon asks the driver once a second, so readiness is *discovered* on the next tick
    /// rather than when it happened, and this takes up to a second however fast the device
    /// really was. That is why a connection is meant to be held open rather than made per
    /// call.
    ///
    /// A deadline missed here is `.notReady` carrying the daemon's latest word on each
    /// status, never `.silent`: bring-up reaches this only after the daemon answered its
    /// request, so what it said, or that it said nothing about the driver, is the reason.
    func wait(for status: Status, by deadline: Deadline) throws(DaemonError) {
        try link.wait(for: status, by: deadline)
    }

    /// Brings one device up: sends its initialize request with `payload`, then waits for
    /// the daemon's word that the device is `ready`, by `deadline`. Both devices start this
    /// way and differ only in the three values, so the bringing up is one function of them.
    /// [LAW:one-type-per-behavior]
    func initialize(_ request: Request, _ payload: [UInt8], until ready: Status, by deadline: Deadline) throws -> Startup {
        // The instant the answer was read, and not the instant this thread woke to it, nor
        // the first frame of the readiness wait - as this did, and low-talker's spike before
        // it - which reports the first status push under a name that says the daemon had not
        // spoken yet, when answering the request is exactly what it just did.
        let answered = try self.request(request, payload, by: deadline)
        try wait(for: ready, by: deadline)
        return Startup(answered: answered - deadline.entered, ready: deadline.spent)
    }

    /// The daemon's status payload, decoded: pairs of (status, value). Pure, and separate
    /// from recording for the reason the framing is - a transposed pair records the wrong
    /// status as true and nothing about that looks wrong at runtime. [LAW:decomposition]
    static func statusPairs(_ pairs: [UInt8]) throws -> [(Status, Bool)] {
        guard pairs.count % 2 == 0 else { throw DaemonError.malformed("a status payload of \(pairs.count) bytes, which is not pairs") }
        return try stride(from: 0, to: pairs.count, by: 2).map { index in
            guard let status = Status(rawValue: pairs[index]) else { throw DaemonError.malformed("status \(pairs[index]), which this was not written for") }
            return (status, pairs[index + 1] != 0)
        }
    }
}

/// What the reading thread, the writing thread and the askers share: the socket, what is
/// waiting to be written, and everything the daemon has said that someone might be
/// waiting on.
///
/// Its own type rather than state on `DaemonConnection` so that the threads hold this and
/// not the connection: a thread holding the connection would keep it alive for as long as
/// the daemon kept talking, and `deinit` would never come. The connection hangs up; the
/// threads notice, end, and let go; the descriptor closes with the last holder.
/// [LAW:no-shared-mutable-globals] One lock guards all of it, and every read and write of
/// the fields below happens under it, save the two only the reading thread touches.
///
/// [LAW:single-enforcer] One thread writes, and nothing else does. Frames go out in the
/// order they were asked for, from one queue, and no lock is held across a write: a peer
/// that stops draining stalls the writer and the frames behind it, and every asker still
/// ends its wait by its own deadline.
private final class Link: @unchecked Sendable {
    private let socket: Int32
    private let timeline: Timeline
    private let heartbeatInterval: Duration
    private let patience: Duration
    private let whenLost: @Sendable (DaemonError) -> Void
    private let readingEnded: @Sendable () -> Void
    private let guarded = NSCondition()
    private var nextRequestID: UInt64 = 1

    /// How far a request has got: waiting its turn, being written, written, or answered,
    /// and when. [LAW:one-source-of-truth] One table rather than a set of the asked and a
    /// set of the answered: an id is here while its asker waits on it and nowhere once it
    /// does not, which is also what keeps a request whose asker has gone from being written.
    private enum Progress: Equatable {
        case waiting(Unanswered.Reach)
        case answered(Instant)
    }
    private var requests: [UInt64: Progress] = [:]

    /// A frame waiting for the writer, with the request it carries, if it carries one.
    private struct Outgoing {
        let bytes: [UInt8]
        let request: (id: UInt64, deadline: Deadline)?
    }
    private var outbox: [Outgoing] = []

    var status: [DaemonConnection.Status: Bool] = [:]
    /// When the daemon last sent a byte, and when the next heartbeat is due. Read and written
    /// by the reading thread alone once it runs, so they need no lock: nothing else has a
    /// reason to know. Set here, when the link is made, so a test that moves its clock
    /// before the thread has started still moves it past them.
    ///
    /// On the uptime clock, which stops with the Mac: the silence that says anything about
    /// the daemon is silence while both were awake, and a clock that ran on through the lid
    /// being closed would find the daemon fifteen seconds gone the instant it opened.
    /// [LAW:no-ambient-temporal-coupling]
    private var lastHeard: Instant
    private var heartbeatDue: Instant
    /// Set once, by whichever side ended the connection, and never cleared: every wait
    /// after it throws this, because the daemon cannot answer on a stream that is gone.
    private var failure: DaemonError?
    /// True when this side hung up, so the end of the stream that follows is not reported
    /// as the daemon's doing.
    private var hungUp = false

    init(socket: Int32, timeline: Timeline, heartbeatEvery interval: Duration, patience: Duration, whenLost: @escaping @Sendable (DaemonError) -> Void, readingEnded: @escaping @Sendable () -> Void) {
        self.socket = socket
        self.timeline = timeline
        heartbeatInterval = interval
        self.patience = patience
        self.whenLost = whenLost
        self.readingEnded = readingEnded
        lastHeard = timeline.now()
        heartbeatDue = lastHeard + interval
    }

    deinit {
        close(socket)
    }

    var currentStatus: [DaemonConnection.Status: Bool] {
        guarded.lock(); defer { guarded.unlock() }
        return status
    }

    // MARK: Asking

    /// Queues a request frame for the writer and waits for its answer by `deadline`,
    /// answering when the answer was read. Ends, in this order of precedence: answered, the
    /// connection ended, or the deadline passed - an answer that arrived is an answer, even
    /// on a stream that ended just after it. [LAW:no-silent-failure] Either of the others
    /// says how far the request got.
    ///
    /// A deadline that has passed before the request is queued writes nothing, and one that
    /// passes while it waits its turn takes it out of the queue: the writer takes a request
    /// only while its asker still waits on it and its deadline has not passed, under the
    /// lock the asker decides under, so a request said to be unsent is never written.
    func ask(_ body: [UInt8], by deadline: Deadline) throws(Unanswered) -> Instant {
        guarded.lock(); defer { guarded.unlock() }
        if let failure { throw Unanswered(reach: .unsent, cause: .connection(failure)) }
        guard !deadline.passed else { throw Unanswered(reach: .unsent, cause: .deadline(deadline.refusal)) }
        let id = nextRequestID
        nextRequestID += 1
        requests[id] = .waiting(.unsent)
        // On every way out, so an answer to a request nobody waits on any more is dropped
        // at the door rather than kept for a collector that never comes.
        defer { requests[id] = nil }
        outbox.append(Outgoing(bytes: Frame.request(id: id, payload: body).bytes, request: (id, deadline)))
        guarded.broadcast()
        while true {
            // [LAW:no-defensive-null-guards] The entry is this call's from above to the
            // `defer`, and nothing else removes it.
            switch requests[id]! {
            case .answered(let at):
                return at
            case .waiting(let reach):
                if let failure { throw Unanswered(reach: reach, cause: .connection(failure)) }
                if deadline.passed { throw Unanswered(reach: reach, cause: .deadline(deadline.refusal)) }
            }
            _ = deadline.wait(on: guarded)
        }
    }

    /// Blocks until the daemon's latest word is that `status` holds, the connection has
    /// failed, or the deadline passes, in that order of precedence. A deadline missed is
    /// `.notReady` with the daemon's latest word on each status.
    func wait(for status: DaemonConnection.Status, by deadline: Deadline) throws(DaemonError) {
        guarded.lock(); defer { guarded.unlock() }
        while true {
            if self.status[status] == true { return }
            if let failure { throw failure }
            guard !deadline.passed else { throw .notReady(awaiting: status, said: self.status) }
            _ = deadline.wait(on: guarded)
        }
    }

    /// Queues a frame no one waits on an answer to. Only ever called with the lock held.
    private func enqueue(_ frame: Frame) {
        outbox.append(Outgoing(bytes: frame.bytes, request: nil))
        guarded.broadcast()
    }

    // MARK: The threads

    /// Starts the reader, which reads until the stream ends, and the writer, which writes
    /// until the connection has ended. Each holds this link and nothing else.
    func start() {
        run("DaemonConnection.reader", readUntilTheEnd, then: readingEnded)
        run("DaemonConnection.writer", writeUntilTheEnd)
    }

    private func run(_ name: String, _ body: @escaping () throws -> Void, then ended: @escaping @Sendable () -> Void = {}) {
        let thread = Thread { [self] in
            do {
                try body()
            } catch {
                lost(error as? DaemonError ?? DaemonError.malformed("\(error)"))
            }
            ended()
        }
        thread.name = name
        thread.stackSize = 1 << 20
        thread.start()
    }

    /// The next thing to do is always the same: wait for the daemon, the heartbeat's turn
    /// or the end of the patience, whichever comes first, then do whichever came.
    /// [LAW:dataflow-not-control-flow]
    private func readUntilTheEnd() throws {
        let queue = try watching(EVFILT_READ)
        while true {
            let readable = try ready(queue, by: min(heartbeatDue, lastHeard + patience))
            if timeline.now() >= heartbeatDue {
                guarded.lock()
                enqueue(.control(.heartbeat, payload: []))
                guarded.unlock()
                heartbeatDue += heartbeatInterval
            }
            if readable {
                try handle(try readFrame(queue))
            }
            guard timeline.now() < lastHeard + patience else { throw DaemonError.silent }
        }
    }

    /// Writes what is queued, in order, until the connection has ended. A request is marked
    /// written once the last of it has gone.
    private func writeUntilTheEnd() throws {
        let queue = try watching(EVFILT_WRITE)
        while let next = nextToWrite() {
            try write(next.bytes, on: queue)
            guard let id = next.request?.id else { continue }
            guarded.lock()
            if requests[id] == .waiting(.writing) { requests[id] = .waiting(.written) }
            guarded.broadcast()
            guarded.unlock()
        }
    }

    /// The next frame to write, or nil once the connection has ended. A request is taken
    /// only while its asker waits on it and before its deadline: one whose turn came late
    /// is left unsent, then and for good.
    private func nextToWrite() -> Outgoing? {
        guarded.lock(); defer { guarded.unlock() }
        while true {
            if failure != nil || hungUp { return nil }
            guard !outbox.isEmpty else { guarded.wait(); continue }
            let next = outbox.removeFirst()
            guard let request = next.request else { return next }
            guard requests[request.id] == .waiting(.unsent), !request.deadline.passed else { continue }
            requests[request.id] = .waiting(.writing)
            return next
        }
    }

    /// What every frame means to this side: a pushed status is recorded and answered with
    /// an empty response, as pqrs's own client does; a health check is answered; a
    /// response's status pairs are recorded and the request it answers is marked answered,
    /// now, for whoever asked.
    private func handle(_ frame: Frame) throws {
        guarded.lock(); defer { guarded.unlock() }
        switch frame {
        case .control(.healthCheck, _):
            enqueue(.control(.healthCheckResponse, payload: []))
        case .control:
            break
        case .request(let id, let payload):
            try record(payload)
            enqueue(.response(id: id, payload: []))
        case .response(let id, let payload):
            try record(payload)
            // Only a request still waited on: an answer to a forgotten one records nothing.
            if requests[id] != nil { requests[id] = .answered(timeline.now()) }
        }
        guarded.broadcast()
    }

    /// Records what the daemon said about its status. Version skew throws from here, before
    /// the frame that carried it can count as an answer: a waiter woken by the loss then
    /// finds the failure and not an acknowledgement. [LAW:single-enforcer] A driver built
    /// for another protocol accepts reports and then does something other than what they
    /// say, so there is no degraded mode to continue into.
    ///
    /// A status taken back throws from here the same way, and ends the connection with it.
    /// The daemon goes on answering a posted report after the driver has gone, measured on
    /// studious 2026-10-01, so its answers cannot say the devices are still there; its
    /// status is the only word on that, and it is read on every frame, not only while a
    /// device is being brought up. The driver coming back does not undo it: the daemon
    /// makes the devices afresh on the same connection, and whatever was held on the old
    /// ones is not held on the new, which is what a new connection says and an old one
    /// cannot. [LAW:no-silent-failure]
    private func record(_ pairs: [UInt8]) throws {
        let before = status
        for (status, value) in try DaemonConnection.statusPairs(pairs) {
            self.status[status] = value
        }
        guard status[.driverVersionMismatched] != true else { throw DaemonError.driverVersionMismatched }
        let takenBack = before.filter { $0.value && status[$0.key] == false }.keys.min { $0.rawValue < $1.rawValue }
        if let takenBack { throw DaemonError.withdrawn(takenBack, said: status) }
    }

    // MARK: Ending

    /// This side is done. The stream ends for the reader, which is how it stops, and the
    /// writer is woken to find it so.
    func hangUp() {
        guarded.lock()
        hungUp = true
        guarded.broadcast()
        guarded.unlock()
        shutdown(socket, SHUT_RDWR)
    }

    /// The connection ended and this side did not end it. Recorded once, every waiter
    /// woken to throw it, and the owner told - after the lock is released, so an owner
    /// that answers by touching the connection cannot deadlock against this thread.
    private func lost(_ error: DaemonError) {
        guarded.lock()
        let theirs = record(loss: error)
        guarded.unlock()
        if theirs { whenLost(error) }
    }

    /// The locked half of losing the connection: the first loss is the failure every
    /// waiter throws, and every waiter is woken. Answers whether the owner is owed the
    /// news, which is once, and never for an end this side asked for. Only ever called
    /// with the lock held.
    ///
    /// The stream ends here for the daemon too. A loss this side declares - a status taken
    /// back, a version it was not built for, a silence - is on a socket the daemon still
    /// counts as a client, and it keeps that client's devices, and whatever is down on
    /// them, until the client goes: a mouse button held through a keyboard taken back
    /// stayed held. [LAW:single-enforcer] So a connection that has ended has ended on the
    /// wire, whoever still holds the object.
    private func record(loss error: DaemonError) -> Bool {
        let first = failure == nil
        if first { failure = error }
        shutdown(socket, SHUT_RDWR)
        guarded.broadcast()
        return first && !hungUp
    }

    // MARK: The socket

    private func readFrame(_ queue: EventQueue) throws -> Frame {
        let length = try Frame.bodyLength(header: read(4, on: queue))
        return try Frame.decode(body: read(length, on: queue))
    }

    /// Writes `bytes` whole, on the writing thread alone, each chunk waited for within the
    /// patience, like a read: a peer that stops draining without hanging up fills the
    /// kernel's buffer, and that is the same silence a stalled read is.
    private func write(_ bytes: [UInt8], on queue: EventQueue) throws(DaemonError) {
        var offset = 0
        while offset < bytes.count {
            guard try ready(queue, by: timeline.now() + patience) else { throw DaemonError.silent }
            let written = uninterrupted { bytes[offset...].withUnsafeBytes { Darwin.write(socket, $0.baseAddress, $0.count) } }
            // Room reported and gone again before the call: back to waiting for it.
            if written < 0, errno == EAGAIN { continue }
            guard written > 0 else { throw DaemonError.socket("write", errno) }
            offset += written
        }
    }

    /// Reads exactly `count` bytes, each chunk waited for within the patience: a peer that
    /// stops mid-frame is as gone as one that stops between frames.
    private func read(_ count: Int, on queue: EventQueue) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            guard try ready(queue, by: lastHeard + patience) else { throw DaemonError.silent }
            let got = uninterrupted { bytes[offset...].withUnsafeMutableBytes { Darwin.read(socket, $0.baseAddress, $0.count) } }
            if got < 0, errno == EAGAIN { continue }
            guard got > 0 else { throw got == 0 ? DaemonError.closed : DaemonError.socket("read", errno) }
            offset += got
            lastHeard = timeline.now()
        }
        return bytes
    }

    /// A queue of one thread's own that hears the socket ready for `filter`: something to
    /// read, or room to write.
    private func watching(_ filter: Int32) throws(DaemonError) -> EventQueue {
        do {
            let queue = try EventQueue()
            try queue.watch(UInt(socket), filter, EV_ADD)
            return queue
        } catch {
            throw .socket(error.call, error.code)
        }
    }

    /// Whether the socket is ready for what `queue` watches by `instant`. The one wait on
    /// the socket, so the end of the stream, an interrupted call and a failed wait each
    /// have one reading, and a test that moves its clock wakes it. [LAW:single-enforcer]
    private func ready(_ queue: EventQueue, by instant: Instant) throws(DaemonError) -> Bool {
        do {
            return try !queue.events(by: .at(instant, on: timeline), atMost: 1).isEmpty
        } catch {
            throw .socket(error.call, error.code)
        }
    }
}
